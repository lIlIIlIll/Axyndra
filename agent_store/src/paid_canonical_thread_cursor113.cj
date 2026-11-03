package agent_store

import agent_domain.*
import agent_runtime.*

// DATA only. A revision/ordinal is a selector, never a legal cut or Source.
// The original reader still measures and decodes each complete original cell.
// Its SQL callback captures only an actual alias; Native consumers run after
// that read transaction and its root frame have physically returned.
public class SqlitePaidCanonicalThreadCursor113 <: PaidCanonicalThreadCursor113 {
    private let database: SqliteDatabase
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    public init(database: SqliteDatabase, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.database = database; this.allocate = allocate
    }
    // A real paid header loan, not a whole Thread snapshot or a Source.
    // All text columns are invoiced before SELECT copies them; the callback
    // executes after SQL unlock and this owner stays live through consumption.
    public func withHeader(thread: ThreadId, localGuard: () -> Result<Unit>,
        consume: (ThreadRecord) -> Result<Unit>): Result<Unit> {
        let owner = allocate(65536)
        try {
            owner.ensureRetainedPeak(journalStreamAdd(1048576, ownedThreadReadbackMultiply(thread.value.size, 8)))
            let header = try { database.readTransaction<ThreadRecord> { tx: SqliteTransaction =>
                paidCanonicalCursorRequire113(localGuard())
                let parameters = [SqlParameter.Text(thread.value)]
                let lengths = tx.query("SELECT length(CAST(workspace_id AS BLOB)),length(CAST(status AS BLOB))," +
                    "length(CAST(COALESCE(active_turn_id,'') AS BLOB)) FROM threads WHERE id=?", parameters)
                if (lengths.size != 1) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Conflict,
                    "tool.checkpoint_thread_missing", "Checkpoint requires a canonical Thread")) }
                var bytes = thread.value.size
                for (index in 0..3) {
                    let size = journalStreamInteger(lengths[0].required(index))
                    if (size < 0) { throw IllegalStateException("durable Thread header size is invalid") }
                    bytes = journalStreamAdd(bytes, size) }
                owner.ensureRetainedPeak(journalStreamAdd(1048576, ownedThreadReadbackMultiply(bytes, 8)))
                let rows = tx.query("SELECT revision,workspace_id,status,next_item_ordinal,COALESCE(active_turn_id,'') " +
                    "FROM threads WHERE id=?", parameters)
                if (rows.size != 1) { throw IllegalStateException("durable Thread does not exist") }
                let row = rows[0]
                for ((lengthIndex, column) in [(0, 1), (1, 2), (2, 4)]) {
                    if (row.required(column).size != journalStreamInteger(lengths[0].required(lengthIndex))) {
                        throw IllegalStateException("durable Thread header changed") } }
                let active = row.required(4)
                let copied = ThreadRecord(thread, journalStreamInteger(row.required(0)),
                    String.fromUtf8(row.required(1).toArray()), parseThreadStatus(row.required(2)),
                    journalStreamInteger(row.required(3)), activeTurnId: if (active == "") { None<SemanticTurnId> }
                        else { Some(SemanticTurnId(String.fromUtf8(active.toArray()))) })
                paidCanonicalCursorRequire113(localGuard()); copied
            } } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
            catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
            catch (failure: Exception) { throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.checkpoint_thread_load_failed", failure.message), allocate) }
            try { paidCanonicalCursorRequire113(consume(header)); Result<Unit>.Ok(()) }
            catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
            catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
        } finally { owner.close() }
    }
    public func withBoundary(thread: ThreadId, localGuard: () -> Result<Unit>,
        consume: (Int64, Int64) -> Result<Unit>): Result<Unit> {
        let owner = allocate(65536)
        try {
            owner.ensureRetainedPeak(journalStreamAdd(8192, ownedThreadReadbackMultiply(thread.value.size, 8)))
            let boundary = database.readTransaction<(Int64, Int64)> { tx: SqliteTransaction =>
                paidCanonicalCursorRequire113(localGuard())
                let rows = tx.query("SELECT revision,next_item_ordinal FROM threads WHERE id=?", [SqlParameter.Text(thread.value)])
                if (rows.size != 1) { throw IllegalStateException("canonical Thread is absent") }
                let revision = journalStreamInteger(rows[0].required(0))
                let next = journalStreamInteger(rows[0].required(1))
                if (revision < 0 || next < 1) { throw IllegalStateException("canonical Thread boundary is invalid") }
                paidCanonicalCursorRequire113(localGuard()); (revision, next)
            }
            // The consumer is deliberately outside database.readTransaction.
            paidCanonicalCursorRequire113(consume(boundary[0], boundary[1])); Result<Unit>.Ok(())
        } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
        catch (failure: Exception) { throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "thread.readback_failed", failure.message), allocate)
        } finally { owner.close() }
    }
    public func requireBoundary(thread: ThreadId, revision: Int64, nextOrdinal: Int64,
        localGuard: () -> Result<Unit>): Result<Unit> {
        withBoundary(thread, localGuard, { actualRevision, actualNext =>
            if (actualRevision != revision || actualNext != nextOrdinal) {
                ownedThreadReadbackFailure<Unit>("thread.readback_stale")
            } else { Result<Unit>.Ok(()) }
        })
    }
    public func withOrdinal(thread: ThreadId, revision: Int64, nextOrdinal: Int64, ordinal: Int64,
        localGuard: () -> Result<Unit>, current: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemAliasCustody) -> Result<Unit>): Result<Unit> {
        if (revision < 0 || nextOrdinal < 1 || ordinal < 1 || ordinal >= nextOrdinal) {
            return ownedThreadReadbackFailure<Unit>("thread.readback_cut_invalid") }
        paidCanonicalCursorRequire113(current())
        let actualGuard: () -> Result<Unit> = { => paidCanonicalCursorRequire113(localGuard()); Result<Unit>.Ok(()) }
        let capture = PaidCanonicalCursorCapture113()
        let metadata = allocate(65536)
        try {
            metadata.ensureRetainedPeak(journalStreamAdd(8192, ownedThreadReadbackMultiply(thread.value.size, 8)))
            capture.item = Some(database.readTransaction<ItemId> { tx: SqliteTransaction =>
                if (ownedThreadReadbackRevision(tx, thread, revision, actualGuard) != nextOrdinal) {
                    throw IllegalStateException("canonical Thread next ordinal changed") }
                let parameters = [SqlParameter.Text(thread.value), SqlParameter.Int64Value(ordinal)]
                let lengths = tx.query("SELECT length(CAST(id AS BLOB)) FROM items WHERE thread_id=? AND ordinal=?", parameters)
                if (lengths.size != 1) { throw IllegalStateException("canonical history is not ordinal-complete") }
                let bytes = journalStreamInteger(lengths[0].required(0))
                if (bytes < 1) { throw IllegalStateException("canonical Item identity is empty") }
                metadata.ensureRetainedPeak(journalStreamAdd(8192, ownedThreadReadbackMultiply(journalStreamAdd(thread.value.size, bytes), 8)))
                paidCanonicalCursorRequire113(localGuard())
                let rows = tx.query("SELECT id FROM items WHERE thread_id=? AND ordinal=?", parameters)
                if (rows.size != 1 || rows[0].required(0).size != bytes) {
                    throw IllegalStateException("canonical Item identity changed") }
                let independent = ItemId(String.fromUtf8(rows[0].required(0).toArray()))
                if (ownedThreadReadbackRevision(tx, thread, revision, actualGuard) != nextOrdinal) {
                    throw IllegalStateException("canonical Thread next ordinal changed") }
                independent
            })
            let read = capturePaidCursorRow113(thread, revision, capture.item.getOrThrow(), actualGuard, { _, actualRoot =>
                match (actualRoot.retainAliasCustody()) {
                    case Result.Err(error) => Result<Unit>.Err(error)
                    case Result.Ok(actual) => capture.alias = Some(actual); Result<Unit>.Ok(()) }
            })
            capture.item = None<ItemId>
            paidCanonicalCursorRequire113(read)
            capture.ready = true
        } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
        catch (failure: Exception) { throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "thread.readback_failed", failure.message), allocate)
        } finally {
            capture.item = None<ItemId>
            metadata.close()
            if (!capture.ready) {
                match (capture.alias) { case Some(actual) =>
                    capture.alias = None<OwnedCanonicalThreadItemAliasCustody>
                    match (actual.closeAfterAliasRetirement()) { case Result.Ok(_) => ()
                        case Result.Err(_) => throw IllegalStateException("canonical row capture still has an active consumer") }
                    case None => () }
            }
        }
        // Root SQL/row/ID frames and metadata are now gone. Only the actual
        // paid row alias remains. Full Host checks and RPC cannot invert DB locks.
        let actual = capture.alias.getOrThrow(); capture.alias = None<OwnedCanonicalThreadItemAliasCustody>
        try {
            paidCanonicalCursorRequire113(current())
            paidCanonicalCursorRequire113(requireBoundary(thread, revision, nextOrdinal, localGuard))
            let answer = actual.withItem({ item =>
                if (item.threadId.value != thread.value || item.ordinal != ordinal) {
                    return ownedThreadReadbackFailure<Unit>("thread.readback_identity_changed") }
                // A consumer retaining a value must retain its real alias or
                // independently copy/pay it before this callback returns.
                consume(item, actual)
            })
            paidCanonicalCursorRequire113(current())
            paidCanonicalCursorRequire113(requireBoundary(thread, revision, nextOrdinal, localGuard))
            paidCanonicalCursorRequire113(answer); Result<Unit>.Ok(())
        } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
        catch (failure: Exception) { throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "thread.readback_failed", failure.message), allocate) }
        finally {
            // withItem has cleared its callback frame before this actual ACK.
            match (actual.closeAfterAliasRetirement()) {
                case Result.Ok(_) => ()
                case Result.Err(_) => throw IllegalStateException("canonical row alias still has an active consumer") }
        }
    }
    // Same original whole-row meter/decoder/custody. This opt-in wrapper keeps
    // a complete guard AgentError; the original public reader/default remains
    // unchanged, including its legacy error conversion.
    private func capturePaidCursorRow113(thread: ThreadId, revision: Int64, item: ItemId,
        guard: () -> Result<Unit>, consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        let parent = allocate(65536)
        try {
            parent.ensureRetainedPeak(journalStreamAdd(8192,
                ownedThreadReadbackMultiply(journalStreamAdd(thread.value.size, item.value.size), 8)))
            let answer = database.readTransaction<Result<Unit>> { tx: SqliteTransaction =>
                let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
                let at = ownedThreadReadbackSelectedOrdinal(tx, thread, item)
                let answer = ownedThreadReadbackRow(tx, thread, revision, at, Some(item), parent, guard, consume)
                let _ = ownedThreadReadbackRevision(tx, thread, revision, guard); answer }
            // A raw Err produced by the complete row/consume frame is moved
            // to paid failure custody while THIS original parent still lives.
            // The outer metadata frame must not capture it after this finally.
            paidCanonicalCursorRequire113(answer); Result<Unit>.Ok(())
        } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw OwnedCanonicalPaidFailure113(failure.error, allocate) }
        catch (failure: Exception) {
            // Capture before this original parent frame/SQL exception retire.
            throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                "thread.readback_failed", failure.message, retryable: false, fallbackAllowed: false), allocate) }
        finally { parent.close() }
    }
}

func paidCanonicalCursorRequire113(result: Result<Unit>): Unit {
    match (result) { case Result.Ok(_) => (); case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
}

class PaidCanonicalCursorCapture113 {
    var item: ?ItemId = None<ItemId>
    var alias: ?OwnedCanonicalThreadItemAliasCustody = None<OwnedCanonicalThreadItemAliasCustody>
    var ready = false
}
