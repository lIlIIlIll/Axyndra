package agent_product

import agent_host_runtime.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

// These helpers only transport the complete real history. Native owns which
// names and successful pairs constitute an active checkpoint; Kernel callers
// independently keep the original protocol/safe-cut/SQL/epoch checks.
enum NativeCheckpointRetentionFrame173<T> {
    Existing(Result<T>) | Produced(Result<T>, NativeCheckpointRetentionHeld173)
}
func withNativeCheckpointRetention173<T>(host: ProductJavaScriptPluginHost, settingsRoot: String,
    session: SessionId, cancellation: CancellationToken,
    retain: (NativeCheckpointRetentionHeld173) -> Unit,
    collect: () -> Unit,
    consume: (ProductCompactionReferenceQuery, LogicalJsonOwnerReservation) -> Result<T>): Result<T> {
    // All query construction, Native/SQL consumption, catch and borrow helper
    // frames return through this actual synchronous boundary. The produced
    // cell has been linked since before dispatch; it is not an absence proof.
    match (produceNativeCheckpointRetention173<T>(host, settingsRoot, session, cancellation, retain, collect, consume)) {
        case NativeCheckpointRetentionFrame173.Existing(result) => result
        case NativeCheckpointRetentionFrame173.Produced(result, held) =>
            held.returnedProducer173()
            collect()
            result
    }
}

func produceNativeCheckpointRetention173<T>(host: ProductJavaScriptPluginHost, settingsRoot: String,
    session: SessionId, cancellation: CancellationToken,
    retain: (NativeCheckpointRetentionHeld173) -> Unit,
    collect: () -> Unit,
    consume: (ProductCompactionReferenceQuery, LogicalJsonOwnerReservation) -> Result<T>): NativeCheckpointRetentionFrame173<T> {
    let selected = match (loadProductPolicySelection(settingsRoot, "compaction")) {
        case Result.Err(error) => return NativeCheckpointRetentionFrame173<T>.Existing(Result<T>.Err(error)); case Result.Ok(value) => value }
    let binding = match (host.policyProviderBinding(selected.namespace, selected.provider)) {
        case Result.Err(error) => return NativeCheckpointRetentionFrame173<T>.Existing(Result<T>.Err(error)); case Result.Ok(value) => value }
    match (selected.validateBinding(host, binding)) {
        case Result.Err(error) => return NativeCheckpointRetentionFrame173<T>.Existing(Result<T>.Err(error)); case Result.Ok(_) => () }
    let descriptor = match (host.servicePackage(binding.namespace, binding.generation)) {
        case Result.Err(error) => return NativeCheckpointRetentionFrame173<T>.Existing(Result<T>.Err(error)); case Result.Ok(value) => value }
    let owner = try { descriptor.deriveCopiedDataPayment(1048576) } finally { descriptor.close() }
    // Strings, hashing input/output, request/query wrappers and one failure
    // holder are prepaid before any concatenation or constructor allocation.
    var bytes = session.value.size
    for (size in [settingsRoot.size, binding.namespace.size, binding.contribution.size, binding.digest.size]) {
        if (bytes > Int64.Max - size) { owner.close(); return NativeCheckpointRetentionFrame173<T>.Existing(productPolicySelectionError<T>("compaction.structure_invalid")) }
        bytes += size }
    try {
        if (bytes > (Int64.Max - 1064960) / 8) { throw LogicalJsonPayloadError("retention metadata overflow") }
        owner.ensureRetainedPeak(1064960 + bytes * 8)
    } catch (_: Exception) { owner.close(); return NativeCheckpointRetentionFrame173<T>.Existing(productPolicySelectionError<T>("compaction.structure_invalid")) }
    let query = try { ProductCompactionReferenceQuery(host, selected,
        modelPolicySha256Text(session.value + ":checkpoint-retention"), ThreadId(session.value), cancellation,
        "checkpoint-retention", binding) }
        catch (_: Exception) { owner.close(); return NativeCheckpointRetentionFrame173<T>.Existing(productPolicySelectionError<T>("compaction.structure_invalid")) }
    // Metadata, exact session marker and registry link are prepaid above.
    // Register BEFORE any Native/SQL/query consumer starts, not in its catch.
    let held = try { NativeCheckpointRetentionHeld173(session, query, owner) }
        catch (failure: Exception) { query.close(); owner.close(); throw failure }
    try { retain(held) }
    catch (failure: Exception) { query.close(); owner.close(); throw failure }
    let result = executeNativeCheckpointRetentionFrame173<T>(held, query, owner, consume)
    NativeCheckpointRetentionFrame173<T>.Produced(result, held)
}

func executeNativeCheckpointRetentionFrame173<T>(held: NativeCheckpointRetentionHeld173,
    query: ProductCompactionReferenceQuery, owner: LogicalJsonOwnerReservation,
    consume: (ProductCompactionReferenceQuery, LogicalJsonOwnerReservation) -> Result<T>): Result<T> {
    try { consume(query, owner) }
    catch (failure: OwnedCanonicalPaidFailure113) {
        Result<T>.Err(held.adoptPaid173(failure)) }
    catch (failure: ProductCompactionDataError) { Result<T>.Err(held.capture173(failure.error)) }
    catch (failure: OwnedCanonicalDataFailure113) { Result<T>.Err(held.capture173(failure.error)) }
    catch (_: Exception) {
        // Unknown invocation/physical producer state stays linked and paid.
        // Catching an exception never proves a Future/process did not exist.
        held.unknownProducer173()
        productPolicySelectionError<T>("compaction.structure_invalid") }
}

func queryNativeModelCheckpointRetention173(host: ProductJavaScriptPluginHost, settingsRoot: String,
    session: SessionId, messages: Array<ModelMessage>, cancellation: CancellationToken,
    retain: (NativeCheckpointRetentionHeld173) -> Unit, collect: () -> Unit): Result<Int64> {
    withNativeCheckpointRetention173<Int64>(host, settingsRoot, session, cancellation, retain, collect, { query, _ =>
        var total: Int64 = 0
        for (message in messages) {
            if (total > Int64.Max - message.blocks.size) { throw IllegalStateException("history block count overflow") }
            total += message.blocks.size }
        let state = NativeCheckpointModelState173(query.query("checkpoint_model_begin173", [ValueField("total", integerValue(total))]))
        try {
            for (second in [false, true]) {
                if (second) {
                    let next = query.query("checkpoint_model_second173", [ValueField("state", state.value)])
                    query.release(state.value); state.value = next }
                let metadata = query.references.checkpointBatchMetadata113()
                try {
                    for (message in 0..messages.size) {
                        for (block in messages[message].blocks) {
                            state.events.add(objectValue([ValueField("message", integerValue(message)),
                                ValueField("kind", textValue(match (block.kind) {
                                    case ModelBlockKind.ToolCall => "call"; case ModelBlockKind.ToolResult => "result"
                                    case ModelBlockKind.Text => "text"; case _ => "other" })),
                                ValueField("name", query.references.intern(block.name)),
                                ValueField("call", query.references.intern(block.callId)), ValueField("is_error", boolValue(block.isError))]))
                            if (state.events.size == 64) { checkpointModelSendBatch173(query, state) }
                        }
                    }
                    if (!state.events.isEmpty()) { checkpointModelSendBatch173(query, state) }
                } finally { state.events.clear(); metadata.close() }
            }
            let result = query.query("checkpoint_model_finish173", [ValueField("state", state.value)])
            try {
                if (!httpIntentExactFields(result, ["retain"])) { throw IllegalStateException("Native retention contract changed") }
                let at = compactionPageInteger(result, "retain")
                if (at < -1 || at >= messages.size) { throw IllegalStateException("Native retention proposal is outside actual history") }
                query.check(); Result<Int64>.Ok(at)
            } finally { query.release(result) }
        } finally { state.events.clear(); query.release(state.value) }
    })
}
class NativeCheckpointModelState173 {
    var value: AgentValue
    let events = ArrayList<AgentValue>()
    init(value: AgentValue) { this.value = value }
}
func checkpointModelSendBatch173(query: ProductCompactionReferenceQuery, state: NativeCheckpointModelState173): Unit {
    let batch = query.copy(listValue(state.events.toArray()))
    try {
        let next = query.query("checkpoint_model_batch173", [ValueField("state", state.value), ValueField("events", batch)])
        query.release(state.value); state.value = next
    } finally { state.events.clear(); query.release(batch) }
}
func queryNativeCanonicalCheckpointRetention173(host: ProductJavaScriptPluginHost, settingsRoot: String,
    session: SessionId, expected: ThreadRecord, database: SqliteDatabase, cancellation: CancellationToken,
    retain: (NativeCheckpointRetentionHeld173) -> Unit, collect: () -> Unit): Result<Int64> {
    withNativeCheckpointRetention173<Int64>(host, settingsRoot, session, cancellation, retain, collect, { query, owner =>
        let allocate: (Int64) -> LogicalJsonOwnerReservation = { bytes =>
            let child = owner.deriveRetainedLease()
            try { child.ensureRetainedPeak(bytes); child }
            catch (failure: Exception) { child.close(); throw failure } }
        let cursor = SqlitePaidCanonicalThreadCursor113(database, allocate)
        let state = checkpointSaveActualOwnedHistory113(query, cursor, expected.id, expected.revision,
            expected.nextItemOrdinal, "", { => cancellation.check() })
        try {
            let result = query.query("checkpoint_retained_cut173", [ValueField("state", state)])
            try {
                if (!httpIntentExactFields(result, ["retain"])) { throw IllegalStateException("Native retention contract changed") }
                let at = compactionPageInteger(result, "retain")
                if (at < -1 || at >= expected.nextItemOrdinal) { throw IllegalStateException("Native retention proposal is outside actual canonical history") }
                query.check(); compactionDataRequire(cursor.requireBoundary(expected.id, expected.revision,
                    expected.nextItemOrdinal, { => cancellation.check() }))
                Result<Int64>.Ok(at)
            } finally { query.release(result) }
        } finally { query.release(state) }
    })
}
func queryNativeCheckpointRetentionError173(host: ProductJavaScriptPluginHost, settingsRoot: String,
    session: SessionId, cancellation: CancellationToken,
    retain: (NativeCheckpointRetentionHeld173) -> Unit, collect: () -> Unit): Result<Unit> {
    withNativeCheckpointRetention173<Unit>(host, settingsRoot, session, cancellation, retain, collect, { query, _ =>
        let value = query.query("checkpoint_retention_error173", [])
        try {
            let error = value.field("error").getOrThrow()
            if (!httpIntentExactFields(value, ["error"]) || !httpIntentExactFields(error, ["kind", "code", "message", "fields"]) ||
                httpIntentText(error, "kind") != "conflict" || httpIntentText(error, "code") != "session.compaction_checkpoint_active" ||
                httpIntentText(error, "message") != "active checkpoint history cannot fit the compaction target; call rewind before compacting again" ||
                error.field("fields").getOrThrow().unifiedKind != ValueKind.List || !error.field("fields").getOrThrow().items.isEmpty()) {
                throw IllegalStateException("Native checkpoint refusal is outside the original closed error contract") }
            query.check()
            Result<Unit>.Err(AgentError(AgentErrorKind.Conflict, "session.compaction_checkpoint_active",
                "active checkpoint history cannot fit the compaction target; call rewind before compacting again"))
        } finally { query.release(value) }
    })
}
func canonicalCheckpointRetentionFailure173<T>(result: Result<Unit>): Result<T> {
    match (result) { case Result.Err(error) => Result<T>.Err(error)
        case Result.Ok(_) => productPolicySelectionError<T>("compaction.structure_invalid") }
}
