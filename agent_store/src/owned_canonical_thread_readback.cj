package agent_store

import agent_domain.*
import agent_runtime.*

// The existing canonical SQLite rows remain the complete history. Each visit
// reads one complete original cell pair, under one actual revision and one
// original-pool owner; it never materializes a corpus or changes its cut.
public class SqliteOwnedCanonicalThreadReadback <: OwnedCanonicalThreadReadback {
    private let database: SqliteDatabase
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    public init(database: SqliteDatabase, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.database = database; this.allocate = allocate
    }
    public func visit(thread: ThreadId, revision: Int64, afterOrdinal: Int64, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        if (revision < 0 || afterOrdinal < 0) { return ownedThreadReadbackFailure("thread.readback_cut_invalid") }
        var reservation: ?LogicalJsonOwnerReservation = None
        try {
            let parent = allocate(65536); reservation = Some(parent)
            parent.ensureRetainedPeak(journalStreamAdd(8192, ownedThreadReadbackMultiply(thread.value.size, 8)))
            database.readTransaction<Result<Unit>> { tx: SqliteTransaction =>
                let cursor = ownedThreadReadbackRevision(tx, thread, revision, guard)
                if (afterOrdinal >= cursor) { return ownedThreadReadbackFailure("thread.readback_cut_invalid") }
                var next = afterOrdinal + 1
                while (next < cursor) {
                    journalStreamCheck(guard)
                    match (ownedThreadReadbackRow(tx, thread, revision, next, None, parent, guard, consume)) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) => next++ }
                }
                let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
                Result.Ok(())
            }
        } catch (error: Exception) { ownedThreadReadbackFailure("thread.readback_failed", message: error.message) }
        finally { match (reservation) { case Some(parent) => parent.close(); case None => () } }
    }
    public func visitItem(thread: ThreadId, revision: Int64, item: ItemId, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        var reservation: ?LogicalJsonOwnerReservation = None
        try {
            let parent = allocate(65536); reservation = Some(parent)
            parent.ensureRetainedPeak(journalStreamAdd(8192,
                ownedThreadReadbackMultiply(journalStreamAdd(thread.value.size, item.value.size), 8)))
            database.readTransaction<Result<Unit>> { tx: SqliteTransaction =>
                let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
                // The ID comes from the actual caller's canonical metadata; it
                // selects data only and cannot create a Root, Source or receipt.
                let selected = ownedThreadReadbackSelectedOrdinal(tx, thread, item)
                let answer = ownedThreadReadbackRow(tx, thread, revision, selected, Some(item), parent, guard, consume)
                let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
                answer
            }
        } catch (error: Exception) { ownedThreadReadbackFailure("thread.readback_failed", message: error.message) }
        finally { match (reservation) { case Some(parent) => parent.close(); case None => () } }
    }
}

func ownedThreadReadbackFailure<T>(code: String, message!: String = "complete canonical data requires its actual paid readback"): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message, retryable: false, fallbackAllowed: false))
}

func ownedThreadReadbackMultiply(value: Int64, factor: Int64): Int64 {
    if (value < 0 || factor < 1 || value > Int64.Max / factor) {
        throw IllegalStateException("canonical readback payment overflow") }
    value * factor
}

func ownedThreadReadbackRevision(tx: SqliteTransaction, thread: ThreadId, revision: Int64,
    guard: () -> Result<Unit>): Int64 {
    journalStreamCheck(guard)
    let rows = tx.query("SELECT revision,next_item_ordinal FROM threads WHERE id=?", [SqlParameter.Text(thread.value)])
    if (rows.size != 1 || journalStreamInteger(rows[0].required(0)) != revision) {
        throw IllegalStateException("canonical Thread revision is stale or absent") }
    let next = journalStreamInteger(rows[0].required(1))
    if (next < 1) { throw IllegalStateException("canonical Thread ordinal is invalid") }
    journalStreamCheck(guard); next
}

func ownedThreadReadbackRow(tx: SqliteTransaction, thread: ThreadId, revision: Int64, ordinal: Int64, expected: ?ItemId,
    parent: LogicalJsonOwnerReservation, guard: () -> Result<Unit>,
    consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
    let owner = parent.deriveRetainedLease()
    var custody: ?OwnedCanonicalThreadItemCustody = None
    var decoded: ?ThreadItem = None
    try {
        owner.ensureRetainedPeak(8192)
        let parameters = [SqlParameter.Text(thread.value), SqlParameter.Int64Value(ordinal)]
        let suffix = " FROM items WHERE thread_id=? AND ordinal=?"
        // Read numeric lengths before any header or encoded String is copied.
        let lengths = tx.query("SELECT length(CAST(id AS BLOB)),length(CAST(turn_id AS BLOB))," +
            "length(CAST(kind AS BLOB)),length(CAST(payload AS BLOB)),length(CAST(provenance AS BLOB))" + suffix, parameters)
        if (lengths.size != 1) { throw IllegalStateException("canonical history is not ordinal-complete") }
        var headers: Int64 = 0
        for (at in 0..3) { headers = journalStreamAdd(headers, journalStreamInteger(lengths[0].required(at))) }
        let payloadBytes = journalStreamInteger(lengths[0].required(3))
        let provenanceBytes = journalStreamInteger(lengths[0].required(4))
        if (headers < 0 || payloadBytes < 1 || payloadBytes > 8388608 || provenanceBytes < 1 || provenanceBytes > 8388608) {
            throw IllegalStateException("canonical cell violates its original Store codec extent") }
        let headerPeak = journalStreamAdd(8192, ownedThreadReadbackMultiply(headers, 8))
        let payload = contextReadMetadataMeasureOwned(tx, "payload", suffix, parameters, owner, headerPeak, guard)
        let provenance = contextReadMetadataMeasureOwned(tx, "provenance", suffix, parameters, owner, headerPeak, guard)
        if (payload.bytes != payloadBytes || provenance.bytes != provenanceBytes) {
            throw IllegalStateException("canonical cell extent changed") }
        let bytes = journalStreamAdd(payloadBytes, provenanceBytes)
        let nodes = journalStreamAdd(payload.nodes, provenance.nodes)
        // SUM: the actual SQLite column text -> byte Array -> String path
        // needs four whole byte extents; original StoredValue decode/payment
        // needs eight extents for slices/DOM/typed coexistence. Both cells,
        // all structural/typed cells and scanner duplicate keys are added.
        let peak = journalStreamAdd(headerPeak, journalStreamAdd(4194304,
            journalStreamAdd(ownedThreadReadbackMultiply(bytes, 12), ownedThreadReadbackMultiply(nodes, 1024))))
        owner.ensureRetainedPeak(peak)
        journalStreamCheck(guard)
        // This helper's frame ends before the consumer may retain the item.
        // No SQL row/String/meter/temporary root remains during alias ACK.
        decoded = Some(ownedThreadReadbackDecode(tx, thread, ordinal, expected, parameters, suffix,
            headers, payload, provenance, owner, headerPeak, guard))
        let actual = OwnedCanonicalThreadItemCustody(decoded.getOrThrow(), owner)
        custody = Some(actual); decoded = None
        let answer = actual.withItem { item => consume(item, actual) }
        journalStreamCheck(guard)
        let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
        answer
    } finally {
        decoded = None
        match (custody) {
            case Some(actual) => let _ = actual.closeAfterConsumption()
            case None => owner.close() }
    }
}

func ownedThreadReadbackDecode(tx: SqliteTransaction, thread: ThreadId, ordinal: Int64, expected: ?ItemId,
    parameters: Array<SqlParameter>, suffix: String, headerBytes: Int64,
    payload: ContextReadMetadataCell, provenance: ContextReadMetadataCell,
    owner: LogicalJsonOwnerReservation, headerPeak: Int64, guard: () -> Result<Unit>): ThreadItem {
    let rows = tx.query("SELECT id,turn_id,ordinal,kind,payload,provenance,created_at_millis" + suffix, parameters)
    if (rows.size != 1) { throw IllegalStateException("canonical row changed") }
    let row = rows[0]
    if (row.required(4).size != payload.bytes || row.required(5).size != provenance.bytes ||
        journalStreamAdd(row.required(0).size, journalStreamAdd(row.required(1).size, row.required(3).size)) != headerBytes ||
        journalStreamInteger(row.required(2)) != ordinal || (expected.isSome() && row.required(0) != expected.getOrThrow().value)) {
        throw IllegalStateException("canonical row identity or extent changed") }
    let payloadMeter = StoredValuePaymentMeter(row.required(4), owner,
        extraRetained: journalStreamAdd(headerPeak, contextReadMetadataRawPeak(provenance.bytes)))
    let provenanceMeter = StoredValuePaymentMeter(row.required(5), owner,
        extraRetained: journalStreamAdd(headerPeak, contextReadMetadataRawPeak(payload.bytes)))
    if (payloadMeter.complete() != payload.nodes || provenanceMeter.complete() != provenance.nodes) {
        throw IllegalStateException("canonical cell grammar or node extent changed") }
    let content = decodeStoredThreadContent(row.required(4))
    if (storedItemKind(threadItemKind(content)) != row.required(3)) {
        throw IllegalStateException("durable Item kind and payload disagree") }
    let item = ThreadItem(ItemId(row.required(0)), thread, SemanticTurnId(row.required(1)), ordinal,
        content, decodeStoredProvenance(row.required(5)), createdAtMillis: journalStreamInteger(row.required(6)))
    if(isCompletedInitiatorHistory173e(item)){
        completedInitiatorRequireHistory173e(tx,item,owner,journalStreamAdd(headerPeak,journalStreamAdd(4194304,
            journalStreamAdd(ownedThreadReadbackMultiply(journalStreamAdd(payload.bytes,provenance.bytes),12),
                ownedThreadReadbackMultiply(journalStreamAdd(payload.nodes,provenance.nodes),1024)))),guard)}
    journalStreamCheck(guard); item
}

// This exact numeric selector frame ends before a complete canonical row is
// read or handed to a consumer. It neither creates Source nor retains rows.
func ownedThreadReadbackSelectedOrdinal(tx: SqliteTransaction, thread: ThreadId, item: ItemId): Int64 {
    let rows = tx.query("SELECT ordinal FROM items WHERE thread_id=? AND id=?",
        [SqlParameter.Text(thread.value), SqlParameter.Text(item.value)])
    if (rows.size != 1) { throw IllegalStateException("canonical Item is missing or duplicated") }
    journalStreamInteger(rows[0].required(0))
}
