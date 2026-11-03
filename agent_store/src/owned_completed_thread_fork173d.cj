package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.overflow.*
import yjson.*
import yjson_support.*

// Historical DATA only. The actual selected, installed policy supplies this
// original-pool owner and a local current/cancellation loan. Neither a Native
// name, a digest nor these copied rows can grant a Source or replay an action.
public class SqliteOwnedCompletedThreadFork173d {
    private let database: SqliteDatabase
    public init(database: SqliteDatabase) { this.database = database }
    public func fork173d(source: ThreadId, target: ThreadId, workspace: String,
        owner: LogicalJsonOwnerReservation, current: () -> Result<Unit>): Result<Unit> {
        // Pay parameters, SQL/helper frames and scalar state before allocating
        // them. The owner stays in the prelinked maintenance cell until ALL
        // transaction/encoder/decoder/handler frames have actually returned.
        let payment = CompletedForkPayment173d(owner, source, target, workspace)
        let stage = CompletedForkStage173d()
        try {
            database.transaction<Unit> { tx =>
                journalStreamCheck(current)
                let header = completedForkHeader173d(tx, source, payment, current)
                let original = completedForkScan173d(tx, source, header, payment, current, 0)
                let sourceTurns = completedForkValidateTurns173d(tx, source, header, payment, current, false)
                let sourceUserEvidence174 = completedUserThreadEvidence174(tx, source, header, payment, current)
                stage.value = "seed"
                if (!tx.query("SELECT id FROM threads WHERE id=?", [SqlParameter.Text(target.value)]).isEmpty()) {
                    throw IllegalStateException("canonical Thread already exists") }
                tx.execute("INSERT INTO threads (id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                    "VALUES (?,1,?,'open',?,NULL)", [SqlParameter.Text(target.value), SqlParameter.Text(workspace),
                        SqlParameter.Int64Value(header.next)])
                completedForkInsertTurns173d(tx, source, target, header, payment, current)
                var ordinal: Int64 = 1
                while (ordinal < header.next) {
                    completedForkWithItem173d(tx, source, header.revision, ordinal, payment, current, { item, rawBytes, nodes =>
                        completedForkInsertItem173d(tx, item, target, payment, rawBytes, nodes, current)
                        // The complete target codec/history helper has returned;
                        // clearing a transient counter refunds no bank.
                        payment.copyPeak = 0
                        completedUserCopyHistory174(tx, item, target, payment, current)
                    })
                    ordinal++
                }
                // Legal SQLite triggers must not substitute a different source,
                // prefix, mapping or payload without moving its revision.
                let sourceAfter = completedForkScan173d(tx, source, header, payment, current, 0)
                if (sourceAfter != original) { throw IllegalStateException("completed source changed during its exact copy") }
                if (completedUserThreadEvidence174(tx, source, header, payment, current) != sourceUserEvidence174) {
                    throw IllegalStateException("User/model source graph changed during its historical copy") }
                let targetHeader = CompletedForkHeader173d(1, header.next, "open", workspace, "")
                let targetDigest = completedForkScan173d(tx, target, targetHeader, payment, current, 0)
                let targetTurns = completedForkValidateTurns173d(tx, target, targetHeader, payment, current, true)
                let targetUserEvidence174 = completedUserThreadEvidence174(tx, target, targetHeader, payment, current)
                stage.value = "checkpoint"
                completedForkCopyCheckpoint173d(tx, source, target, header, targetHeader, payment, current)
                completedForkRequireHeader173d(tx, source, header, payment, current)
                completedForkRequireHeader173d(tx, target, targetHeader, payment, current)
                // A checkpoint INSERT trigger can mutate otherwise immutable
                // Items too; recheck the full original prefix after that write.
                if (completedForkScan173d(tx, source, header, payment, current, 0) != original) {
                    throw IllegalStateException("completed source changed after checkpoint copy") }
                if (completedForkScan173d(tx, target, targetHeader, payment, current, 0) != targetDigest) {
                    throw IllegalStateException("completed target changed after checkpoint copy") }
                if (completedUserThreadEvidence174(tx, source, header, payment, current) != sourceUserEvidence174 ||
                    completedUserThreadEvidence174(tx, target, targetHeader, payment, current) != targetUserEvidence174) {
                    throw IllegalStateException("User/model source or target evidence changed after checkpoint copy") }
                if (completedForkValidateTurns173d(tx, source, header, payment, current, false) != sourceTurns ||
                    completedForkValidateTurns173d(tx, target, targetHeader, payment, current, true) != targetTurns) {
                    throw IllegalStateException("completed Turn mapping changed after checkpoint copy") }
                completedForkRequireSeedRuns173d(tx, target, targetHeader, payment, current)
                journalStreamCheck(current)
            }
            Result<Unit>.Ok(())
        } catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw failure }
        catch (failure: PluginDocumentGuardFailure) { throw OwnedCanonicalDataFailure113(failure.failure) }
        catch (failure: Exception) {
            // This same original bank is still held by the installed, prelinked
            // cell. Its capture stores the complete original error BEFORE a
            // fallible independent-consumer invoice; pressure retains that cell.
            let error = completedForkError173d(stage.value, source, target, failure.message)
            throw OwnedCanonicalDataFailure113(error)
        }
    }
}

class CompletedForkStage173d { var value = "clone" }
class CompletedForkHeader173d {
    let revision: Int64
    let next: Int64
    let status: String
    let workspace: String
    let active: String
    init(revision: Int64, next: Int64, status: String, workspace: String, active: String) {
        this.revision = revision; this.next = next; this.status = status; this.workspace = workspace; this.active = active }
}

class CompletedForkPayment173d {
    let owner: LogicalJsonOwnerReservation
    private let metadata: Int64
    var rowPeak: Int64 = 0
    var pendingBytes: Int64 = 0
    var pendingCount: Int64 = 0
    var headerBytes: Int64 = 0
    var copyPeak: Int64 = 0
    var checkpointPeak: Int64 = 0
    init(owner: LogicalJsonOwnerReservation, source: ThreadId, target: ThreadId, workspace: String) {
        this.owner = owner
        this.metadata = journalStreamAdd(131072, ownedThreadReadbackMultiply(
            journalStreamAdd(source.value.size, journalStreamAdd(target.value.size, workspace.size)), 16))
        owner.ensureRetainedPeak(metadata)
    }
    func transient173d(bytes: Int64): Unit {
        owner.ensureRetainedPeak(extra173d(bytes)) }
    func extra173d(bytes: Int64): Int64 {
        journalStreamAdd(journalStreamAdd(metadata, journalStreamAdd(copyPeak, checkpointPeak)), journalStreamAdd(ownedThreadReadbackMultiply(headerBytes, 32), journalStreamAdd(
            journalStreamAdd(ownedThreadReadbackMultiply(pendingBytes, 8), ownedThreadReadbackMultiply(pendingCount, 256)), bytes))) }
    func row173d(bytes: Int64, nodes: Int64): Unit {
        rowPeak = journalStreamAdd(4194304, journalStreamAdd(ownedThreadReadbackMultiply(bytes, 12),
            ownedThreadReadbackMultiply(nodes, 1024)))
        transient173d(rowPeak)
    }
    func simultaneous173d(bytes: Int64): Unit { transient173d(journalStreamAdd(rowPeak, bytes)) }
    func retainCall173d(id: String): Unit {
        pendingBytes = journalStreamAdd(pendingBytes, id.size); pendingCount++
        transient173d(rowPeak)
    }
    func releaseCall173d(id: String): Unit { pendingBytes -= id.size; pendingCount-- }
}

func completedForkError173d(stage: String, source: ThreadId, target: ThreadId, message: String): AgentError {
    if (stage == "clone") {
        return AgentError(AgentErrorKind.Conflict, "product.thread_fork_invalid", message,
            fields: [ErrorField("source_thread_id", source.value), ErrorField("target_thread_id", target.value)]) }
    if (stage == "seed") {
        return AgentError(AgentErrorKind.Conflict, "thread.seed_failed", message,
            fields: [ErrorField("thread_id", target.value)]) }
    AgentError(AgentErrorKind.RecoveryRequired, "context.checkpoint_commit_failed", message)
}

func completedForkHeader173d(tx: SqliteTransaction, thread: ThreadId, payment: CompletedForkPayment173d,
    current: () -> Result<Unit>): CompletedForkHeader173d {
    journalStreamCheck(current)
    let parameters = [SqlParameter.Text(thread.value)]
    let sizes = tx.query("SELECT length(CAST(workspace_id AS BLOB)),length(CAST(status AS BLOB))," +
        "length(CAST(COALESCE(active_turn_id,'') AS BLOB)) FROM threads WHERE id=?", parameters)
    if (sizes.isEmpty()) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.InvalidInput,
        "product.thread_not_found", "canonical Thread does not exist", fields: [ErrorField("thread_id", thread.value)])) }
    if (sizes.size != 1) { throw IllegalStateException("durable Thread does not exist") }
    var bytes: Int64 = 0
    for (at in 0..3) { bytes = journalStreamAdd(bytes, journalStreamInteger(sizes[0].required(at))) }
    payment.headerBytes = max(payment.headerBytes, bytes)
    payment.transient173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(bytes, 16)))
    let rows = tx.query("SELECT revision,next_item_ordinal,status,workspace_id,COALESCE(active_turn_id,'') " +
        "FROM threads WHERE id=?", parameters)
    if (rows.size != 1) { throw IllegalStateException("durable Thread does not exist") }
    let revision = journalStreamInteger(rows[0].required(0)); let next = journalStreamInteger(rows[0].required(1))
    if (revision < 0 || next < 1) { throw IllegalStateException("durable Thread ordinal is invalid") }
    let _ = parseThreadStatus(rows[0].required(2))
    journalStreamCheck(current)
    CompletedForkHeader173d(revision, next, rows[0].required(2), rows[0].required(3), rows[0].required(4))
}
func completedForkRequireHeader173d(tx: SqliteTransaction, thread: ThreadId, expected: CompletedForkHeader173d,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    let actual = completedForkHeader173d(tx, thread, payment, current)
    if (actual.revision != expected.revision || actual.next != expected.next || actual.status != expected.status ||
        actual.workspace != expected.workspace || actual.active != expected.active) {
        throw IllegalStateException("completed Thread header changed inside its exact copy") }
}

// Package-only synchronous loan. It cannot return a ThreadItem, DOM, cursor or
// owner to Product. Numeric extents and the original complete StoredValue grammar
// precede the existing decoder; each real row/codec/SQL/helper frame returns
// before the next Item is read. No full-thread snapshot is manufactured.
func completedForkWithItem173d(tx: SqliteTransaction, thread: ThreadId, revision: Int64, ordinal: Int64,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>, consume: (ThreadItem, Int64, Int64) -> Unit): Unit {
    let parameters = [SqlParameter.Text(thread.value), SqlParameter.Int64Value(ordinal)]
    let suffix = " FROM items WHERE thread_id=? AND ordinal=?"
    journalStreamCheck(current)
    let lengths = tx.query("SELECT length(CAST(id AS BLOB)),length(CAST(turn_id AS BLOB))," +
        "length(CAST(kind AS BLOB)),length(CAST(payload AS BLOB)),length(CAST(provenance AS BLOB))" + suffix, parameters)
    if (lengths.size != 1) { throw IllegalStateException("canonical history is not ordinal-complete") }
    var headers: Int64 = 0
    for (at in 0..3) { headers = journalStreamAdd(headers, journalStreamInteger(lengths[0].required(at))) }
    let payloadBytes = journalStreamInteger(lengths[0].required(3)); let provenanceBytes = journalStreamInteger(lengths[0].required(4))
    if (headers < 0 || payloadBytes < 1 || payloadBytes > 8388608 || provenanceBytes < 1 || provenanceBytes > 8388608) {
        throw IllegalStateException("canonical cell violates its original Store codec extent") }
    let headerPeak = journalStreamAdd(65536, ownedThreadReadbackMultiply(headers, 16))
    // The meter itself and raw SQL copies are funded under the same original
    // owner. Its extraRetained contains the persistent prefix/header/index SUM.
    let payload = contextReadMetadataMeasureOwned(tx, "payload", suffix, parameters, payment.owner, payment.extra173d(headerPeak), current)
    let provenance = contextReadMetadataMeasureOwned(tx, "provenance", suffix, parameters, payment.owner, payment.extra173d(headerPeak), current)
    let bytes = journalStreamAdd(payload.bytes, provenance.bytes); let nodes = journalStreamAdd(payload.nodes, provenance.nodes)
    payment.row173d(journalStreamAdd(bytes, headers), nodes)
    let item = try { ownedThreadReadbackDecode(tx, thread, ordinal, None<ItemId>, parameters, suffix,
        headers, payload, provenance, payment.owner, payment.extra173d(headerPeak), current) }
        catch (failure: OwnedCanonicalPaidFailure113) { throw failure }
        catch (failure: OwnedCanonicalDataFailure113) { throw failure }
        catch (failure: PluginDocumentGuardFailure) { throw failure }
        catch (failure: Exception) {
            // Match canonicalThreadSnapshot's original decode/read failure;
            // the surrounding prelinked owner pays its full dynamic message.
            throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                "product.canonical_thread_unavailable", failure.message,
                fields: [ErrorField("thread_id", thread.value)])) }

    // The full SQL raw-cell/meter/decoder frames have now returned. Retain only
    // the decoded typed Item and its headers while target writers operate. This
    // changes no reservation/refund; subsequent ensure pays the actual live SUM
    // instead of adding dead decoder buffers to a new encoder's invoice.
    payment.rowPeak = journalStreamAdd(65536, journalStreamAdd(ownedThreadReadbackMultiply(bytes, 2),
        journalStreamAdd(ownedThreadReadbackMultiply(nodes, 512), ownedThreadReadbackMultiply(headers, 16))))
    consume(item, bytes, nodes)
    let _ = ownedThreadReadbackRevision(tx, thread, revision, current)
}

class CompletedForkProtocol173d {
    private let pending = ArrayList<String>()
    private var turn: Int64 = 0
    private let payment: CompletedForkPayment173d
    var coverLegal = true
    init(payment: CompletedForkPayment173d) { this.payment = payment }
    func consume173d(item: ThreadItem, ordinal: Int64, cover: Int64): Unit {
        if (turn != ordinal && !pending.isEmpty()) {
            throw IllegalArgumentException("seed Turn ends with incomplete ToolCall") }
        turn = ordinal
        match (item.content) {
            case ThreadItemContent.ToolCall(id, _, _) =>
                for (value in pending where value == id.value) { throw IllegalArgumentException("seed ToolCall id is duplicated in its Turn") }
                payment.retainCall173d(id.value)
                pending.add(String.fromUtf8(id.value.toArray()))
            case ThreadItemContent.ToolResult(id, _, _, _, _) =>
                var found: Int64 = -1
                for (at in 0..pending.size where pending[at] == id.value) { found = at; break }
                if (found < 0) { throw IllegalArgumentException("seed ToolResult has no pending ToolCall in its Turn") }
                payment.releaseCall173d(pending[found]); pending.remove(at: found)
            case _ => if (!pending.isEmpty()) { throw IllegalArgumentException("seed semantic Item crosses an incomplete tool round") }
        }
        if (cover == item.ordinal && !pending.isEmpty()) { coverLegal = false }
    }
    func finish173d(): Unit {
        if (!pending.isEmpty()) { throw IllegalArgumentException("seed Thread ends with incomplete ToolCall") }
    }
}

func completedForkScan173d(tx: SqliteTransaction, source: ThreadId, header: CompletedForkHeader173d,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>, cover: Int64): String {
    completedForkRequireHeader173d(tx, source, header, payment, current)
    let counts = tx.query("SELECT COUNT(*) FROM items WHERE thread_id=?", [SqlParameter.Text(source.value)])
    if (counts.size != 1 || journalStreamInteger(counts[0].required(0)) != header.next - 1) {
        throw IllegalStateException("canonical Thread prefix is not ordinal-complete") }
    let through = if (cover == 0) { header.next - 1 } else { cover }
    if (through < 0 || through >= header.next) { throw IllegalArgumentException("context source digest cover is outside canonical history") }
    if (through == 0) { return "empty-canonical-thread" }
    let digest = OwnedContextPrefixDigest173d(source, through, { bytes => payment.simultaneous173d(bytes) })
    let protocol = CompletedForkProtocol173d(payment)
    var ordinal: Int64 = 1
    while (ordinal < header.next) {
        completedForkWithItem173d(tx, source, header.revision, ordinal, payment, current, { item, _, _ =>
            // Every Item must name an actual source Turn, even a stale-looking
            // row outside the requested checkpoint prefix.
            let turns = tx.query("SELECT ordinal FROM turns WHERE id=? AND thread_id=?",
                [SqlParameter.Text(item.turnId.value), SqlParameter.Text(source.value)])
            if (turns.size != 1) { throw IllegalArgumentException("seed source Item references a missing Turn") }
            protocol.consume173d(item, journalStreamInteger(turns[0].required(0)), through); digest.consumeItem173d(item)
            if (isCompletedInitiatorHistory173e(item)) {
                completedInitiatorRequireHistory173e(tx,item,payment.owner,payment.extra173d(payment.rowPeak),current)
            } else if(isOwnedDirectInitiator(item) || isInternalModelMaintenanceInitiator(item)) {
                let evidence=CompletedInitiatorPayment173e(payment.owner,payment.extra173d(payment.rowPeak),current)
                let _=completedInitiatorDescribe173e(tx,item,evidence)
            }
            if (isContinuationInitiatorDescription(item) || isContinuationHistoryDescription(item)) {
                completedForkRequireContinuation173d(tx, item, payment, current)
            }
        })
        ordinal++
    }
    protocol.finish173d()
    if (!protocol.coverLegal) { return "checkpoint-splits-tool-round" }
    completedForkRequireHeader173d(tx, source, header, payment, current)
    digest.finish173d()
}

class CompletedForkMetadataDigest173d {
    private var hash: UInt64 = 1469598103934665603
    func text173d(text: String): Unit {
        for (byte in unsafe { text.rawData() }) { hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211) } }
    func frame173d(text: String): Unit { text173d(text.size.toString()); text173d(":"); text173d(text) }
    func finish173d(): String { hash.toString() }
}
class CompletedForkTurn173d {
    let id: String
    let userId: String
    let state: String
    let active: String
    init(id: String, user: String, state: String, active: String) {
        this.id = id; this.userId = user; this.state = state; this.active = active }
}
func completedForkTurnCount173d(tx: SqliteTransaction, thread: ThreadId): Int64 {
    let counts = tx.query("SELECT COUNT(*),COALESCE(MIN(ordinal),1),COALESCE(MAX(ordinal),0) FROM turns WHERE thread_id=?",
        [SqlParameter.Text(thread.value)])
    if (counts.size != 1) { throw IllegalStateException("canonical Turns are missing") }
    let count = journalStreamInteger(counts[0].required(0))
    if (count < 0 || journalStreamInteger(counts[0].required(1)) != 1 || journalStreamInteger(counts[0].required(2)) != count) {
        throw IllegalStateException("canonical Turn ordinal is invalid") }
    count
}
func completedForkTurn173d(tx: SqliteTransaction, thread: ThreadId, ordinal: Int64,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): CompletedForkTurn173d {
    journalStreamCheck(current)
    let parameters = [SqlParameter.Text(thread.value), SqlParameter.Int64Value(ordinal)]
    let suffix = " FROM turns WHERE thread_id=? AND ordinal=?"
    let sizes = tx.query("SELECT length(CAST(id AS BLOB)),length(CAST(user_item_id AS BLOB))," +
        "length(CAST(state AS BLOB)),length(CAST(COALESCE(active_run_id,'') AS BLOB))" + suffix, parameters)
    if (sizes.size != 1) { throw IllegalStateException("canonical Turns are not ordinal-complete") }
    var bytes: Int64 = 0
    for (at in 0..4) { bytes = journalStreamAdd(bytes, journalStreamInteger(sizes[0].required(at))) }
    payment.transient173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(bytes, 16)))
    let rows = tx.query("SELECT id,user_item_id,state,COALESCE(active_run_id,'')" + suffix, parameters)
    if (rows.size != 1) { throw IllegalStateException("canonical Turns changed") }
    let _ = parseTurnState(rows[0].required(2))
    CompletedForkTurn173d(rows[0].required(0), rows[0].required(1), rows[0].required(2), rows[0].required(3))
}
class CompletedForkUser173d { var ordinal: Int64 = 0; var created: Int64 = 0 }
func completedForkUser173d(tx: SqliteTransaction, thread: ThreadId, header: CompletedForkHeader173d,
    turn: CompletedForkTurn173d, payment: CompletedForkPayment173d, current: () -> Result<Unit>): CompletedForkUser173d {
    let rows = tx.query("SELECT ordinal FROM items WHERE thread_id=? AND turn_id=? AND id=?",
        [SqlParameter.Text(thread.value), SqlParameter.Text(turn.id), SqlParameter.Text(turn.userId)])
    if (rows.size != 1) { throw IllegalArgumentException("seed source Turn is missing its user Item") }
    let user = CompletedForkUser173d()
    let ordinal = journalStreamInteger(rows[0].required(0))
    completedForkWithItem173d(tx, thread, header.revision, ordinal, payment, current, { item, _, _ =>
        if (item.id.value != turn.userId || item.turnId.value != turn.id ||
            (item.kind != ItemKind.UserMessage && !isContinuationInitiatorDescription(item) && !isContinuationHistoryDescription(item) &&
                !isOwnedDirectInitiator(item) && !isInternalModelMaintenanceInitiator(item) && !isCompletedInitiatorHistory173e(item))) {
            throw IllegalArgumentException("seed source Turn is missing its user Item") }
        user.ordinal = item.ordinal; user.created = item.createdAtMillis
    })
    user
}
func completedForkValidateTurns173d(tx: SqliteTransaction, thread: ThreadId, header: CompletedForkHeader173d,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>, completed: Bool): String {
    let count = completedForkTurnCount173d(tx, thread)
    let digest = CompletedForkMetadataDigest173d()
    for (ordinal in 1..count + 1) {
        let turn = completedForkTurn173d(tx, thread, ordinal, payment, current)
        if (completed && (turn.state != "completed" || turn.active != "")) {
            throw IllegalStateException("seed Thread may contain only completed Turns") }
        digest.frame173d(turn.id); digest.frame173d(ordinal.toString()); digest.frame173d(turn.userId)
        digest.frame173d(turn.state); digest.frame173d(turn.active)
        let _ = completedForkUser173d(tx, thread, header, turn, payment, current)
    }
    digest.finish173d()
}
func completedForkInsertTurns173d(tx: SqliteTransaction, source: ThreadId, target: ThreadId,
    header: CompletedForkHeader173d, payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    let count = completedForkTurnCount173d(tx, source)
    for (ordinal in 1..count + 1) {
        let turn = completedForkTurn173d(tx, source, ordinal, payment, current)
        let user = completedForkUser173d(tx, source, header, turn, payment, current)
        // Original seed naming and original max(0, Item.createdAtMillis).
        let finished = tx.query("SELECT COALESCE(MAX(created_at_millis),0) FROM items WHERE thread_id=? AND turn_id=?",
            [SqlParameter.Text(source.value), SqlParameter.Text(turn.id)])
        if (finished.size != 1) { throw IllegalStateException("completed seed Turn is missing its Items") }
        payment.transient173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(target.value.size, 32)))
        let targetTurn = "seed-turn-" + target.value + "-" + ordinal.toString()
        let targetRun = "seed-run-" + target.value + "-" + ordinal.toString()
        let targetUser = "seed-item-" + target.value + "-" + user.ordinal.toString()
        let empty = encodeStoredValue(objectValue([]))
        tx.execute("INSERT INTO turns (id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES (?,?,?,'completed',?,NULL)",
            [SqlParameter.Text(targetTurn), SqlParameter.Text(target.value), SqlParameter.Int64Value(ordinal), SqlParameter.Text(targetUser)])
        tx.execute("INSERT INTO runs (id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
            "started_at_millis,finished_at_millis,cancellation_reason) VALUES (?,?,?,?,'completed',?,?,?,?,?,?,NULL)",
            [SqlParameter.Text(targetRun), SqlParameter.Text(target.value), SqlParameter.Text(targetTurn), SqlParameter.Int64Value(ordinal),
                SqlParameter.Text(empty), SqlParameter.Text(empty), SqlParameter.Text(empty), SqlParameter.Text(empty),
                SqlParameter.Int64Value(user.created), SqlParameter.Int64Value(max(0, journalStreamInteger(finished[0].required(0))))])
        completedForkRequireTurn173d(tx, target, targetTurn, targetRun, targetUser, ordinal, user.created,
            max(0, journalStreamInteger(finished[0].required(0))), empty)
        journalStreamCheck(current)
    }
}
func completedForkRequireTurn173d(tx: SqliteTransaction, target: ThreadId, turn: String, run: String,
    user: String, ordinal: Int64, started: Int64, finished: Int64, empty: String): Unit {
    // Compare every complete expected field inside SQLite. A legal trigger
    // may enlarge actual DATA to any length; it must never become an unpaid
    // driver String before the equality rejects it. COUNT is a fixed scalar.
    let rows = tx.query("SELECT COUNT(*) FROM turns t JOIN runs r ON r.turn_id=t.id AND r.thread_id=t.thread_id " +
        "WHERE t.thread_id=? AND t.id=? AND r.id=? AND CAST(t.ordinal AS TEXT)=? " +
        "AND CAST(t.state AS BLOB)=CAST(? AS BLOB) AND CAST(t.user_item_id AS BLOB)=CAST(? AS BLOB) " +
        "AND COALESCE(t.active_run_id,'')='' AND CAST(r.epoch AS TEXT)=? AND CAST(r.state AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(r.lane_snapshot AS BLOB)=CAST(? AS BLOB) AND CAST(r.skill_snapshot AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(r.budget AS BLOB)=CAST(? AS BLOB) AND CAST(r.usage AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(r.started_at_millis AS TEXT)=? AND CAST(r.finished_at_millis AS TEXT)=? " +
        "AND COALESCE(r.cancellation_reason,'')=''",
        [SqlParameter.Text(target.value), SqlParameter.Text(turn), SqlParameter.Text(run), SqlParameter.Text(ordinal.toString()),
            SqlParameter.Text("completed"), SqlParameter.Text(user), SqlParameter.Text(ordinal.toString()),
            SqlParameter.Text("completed"), SqlParameter.Text(empty), SqlParameter.Text(empty), SqlParameter.Text(empty),
            SqlParameter.Text(empty), SqlParameter.Text(started.toString()), SqlParameter.Text(finished.toString())])
    if (rows.size != 1 || journalStreamInteger(rows[0].required(0)) != 1) {
        throw IllegalStateException("completed seed Run changed") }

}

// After all Item/history/checkpoint INSERT triggers have run, require the
// complete original seed Run fields again. Empty DATA snapshots cannot become
// a new execution budget/lane, active owner, cancellation or unfinished Run.
func completedForkRequireSeedRuns173d(tx: SqliteTransaction, target: ThreadId, header: CompletedForkHeader173d,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    let count = completedForkTurnCount173d(tx, target)
    let actual = tx.query("SELECT COUNT(*) FROM runs WHERE thread_id=?", [SqlParameter.Text(target.value)])
    if (actual.size != 1 || journalStreamInteger(actual[0].required(0)) != count) {
        throw IllegalStateException("completed seed Run set changed") }
    for (ordinal in 1..count + 1) {
        let turn = completedForkTurn173d(tx, target, ordinal, payment, current)
        let user = completedForkUser173d(tx, target, header, turn, payment, current)
        let finished = tx.query("SELECT COALESCE(MAX(created_at_millis),0) FROM items WHERE thread_id=? AND turn_id=?",
            [SqlParameter.Text(target.value), SqlParameter.Text(turn.id)])
        if (finished.size != 1) { throw IllegalStateException("completed seed Run timestamps changed") }
        payment.transient173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(target.value.size, 32)))
        completedForkRequireTurn173d(tx, target, "seed-turn-" + target.value + "-" + ordinal.toString(),
            "seed-run-" + target.value + "-" + ordinal.toString(), turn.userId, ordinal, user.created,
            max(0, journalStreamInteger(finished[0].required(0))), encodeStoredValue(objectValue([])))
    }
}

func completedForkCloneItem173d(tx: SqliteTransaction, source: ThreadItem, target: ThreadId,
    payment: CompletedForkPayment173d,current: () -> Result<Unit>): ThreadItem {
    let turns = tx.query("SELECT ordinal FROM turns WHERE thread_id=? AND id=?",
        [SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.turnId.value)])
    if (turns.size != 1) { throw IllegalArgumentException("seed source Item references a missing Turn") }
    let ordinal = journalStreamInteger(turns[0].required(0))
    let targetTurn = SemanticTurnId("seed-turn-" + target.value + "-" + ordinal.toString())
    let run = RunId("seed-run-" + target.value + "-" + ordinal.toString())
    let content = match (source.content) {
        case ThreadItemContent.ToolResult(call, _, receipt, result, error) => ThreadItemContent.ToolResult(call,
            OperationId("seed-operation-" + target.value + "-" + source.ordinal.toString()), receipt, result, error)
        case value => value }
    let operation: ?OperationId = match (content) { case ThreadItemContent.ToolResult(_, value, _, _, _) => Some(value)
        case _ => None<OperationId> }
    let provenance = if(isOwnedDirectInitiator(source) || isInternalModelMaintenanceInitiator(source) || isCompletedInitiatorHistory173e(source)) {
        let evidence=CompletedInitiatorPayment173e(payment.owner,payment.extra173d(payment.rowPeak),current)
        ItemProvenance("completed_initiator_history",runId:Some(run),
            completedInitiatorHistory173e:Some(completedInitiatorDescribe173e(tx,source,evidence)))
    } else if (isContinuationInitiatorDescription(source) || isContinuationHistoryDescription(source)) {
        ItemProvenance("continuation_history", runId: Some(run), continuationHistory: Some(ContinuationHistorySource(
            source.threadId.value, source.turnId.value, source.provenance.runId.getOrThrow().value, source.id.value,
            if (isContinuationInitiatorDescription(source)) { source.provenance.continuationOrigin.getOrThrow().requestDigest }
            else { source.provenance.continuationHistory.getOrThrow().requestDigest })))
    } else { ItemProvenance("fork", runId: Some(run), operationId: operation) }
    ThreadItem(ItemId("seed-item-" + target.value + "-" + source.ordinal.toString()), target, targetTurn,
        source.ordinal, content, provenance, createdAtMillis: source.createdAtMillis)
}
func completedForkInsertItem173d(tx: SqliteTransaction, item: ThreadItem, target: ThreadId,
    payment: CompletedForkPayment173d, rawBytes: Int64, nodes: Int64, current: () -> Result<Unit>): Unit {
    payment.copyPeak = journalStreamAdd(65536, journalStreamAdd(ownedThreadReadbackMultiply(rawBytes, 8),
        journalStreamAdd(ownedThreadReadbackMultiply(nodes, 512), ownedThreadReadbackMultiply(target.value.size, 64))))
    payment.simultaneous173d(0)
    let copied = completedForkCloneItem173d(tx, item, target,payment,current)
    let payload = encodeStoredThreadContent(copied.content); let provenance = encodeStoredProvenance(copied.provenance)
    // The original encoders/decoders and complete 8 MiB cells remain the format.
    // Complete byte equality is enforced in SQL, never a hash or header substitute.
    if (payload.size > 8388608 || provenance.size > 8388608) { throw IllegalStateException("stored value exceeds 8 MiB") }
    tx.execute("INSERT INTO items (id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (?,?,?,?,?,?,?,?)",
        [SqlParameter.Text(copied.id.value), SqlParameter.Text(target.value), SqlParameter.Text(copied.turnId.value),
            SqlParameter.Int64Value(copied.ordinal), SqlParameter.Text(seedItemKind(copied.kind)), SqlParameter.Text(payload),
            SqlParameter.Text(provenance), SqlParameter.Int64Value(copied.createdAtMillis)])
    let rows = tx.query("SELECT COUNT(*) FROM items WHERE thread_id=? AND ordinal=? " +
        "AND CAST(id AS BLOB)=CAST(? AS BLOB) AND CAST(turn_id AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(kind AS BLOB)=CAST(? AS BLOB) AND CAST(payload AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(provenance AS BLOB)=CAST(? AS BLOB) AND CAST(created_at_millis AS TEXT)=?",
        [SqlParameter.Text(target.value), SqlParameter.Int64Value(copied.ordinal), SqlParameter.Text(copied.id.value),
            SqlParameter.Text(copied.turnId.value), SqlParameter.Text(seedItemKind(copied.kind)), SqlParameter.Text(payload),
            SqlParameter.Text(provenance), SqlParameter.Text(copied.createdAtMillis.toString())])
    if (rows.size != 1 || journalStreamInteger(rows[0].required(0)) != 1) {
        throw IllegalStateException("completed seed Item changed") }
    if(isCompletedInitiatorHistory173e(copied)) {
        completedInitiatorInsertHistory173e(tx,item,copied,payment.owner,payment.extra173d(payment.rowPeak),current)
    }
    if (isContinuationHistoryDescription(copied)) {
        completedForkPrepayContinuation173d(tx, copied, payment, current)
        insertContinuationHistoryCopy(tx, copied)
    }
    journalStreamCheck(current)
}

// Pay ALL existing historical proof cells before calling their original
// verifier/codec. This is not a claim, consumed launch or source mint.
func completedForkPrepayContinuation173d(tx: SqliteTransaction, item: ThreadItem,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    completedForkPrepaySourceReference173d(tx, item.provenance.continuationHistory.getOrThrow(), payment, current)
}
func completedForkPrepaySourceReference173d(tx: SqliteTransaction, source: ContinuationHistorySource,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    let parameters = [SqlParameter.Text(source.threadId), SqlParameter.Text(source.itemId)]
    var bytes: Int64 = 0; var nodes: Int64 = 0
    for (column in ["payload", "provenance"]) {
        let cell = contextReadMetadataMeasureOwned(tx, column, " FROM items WHERE thread_id=? AND id=?", parameters,
            payment.owner, payment.extra173d(payment.rowPeak), current)
        bytes = journalStreamAdd(bytes, cell.bytes); nodes = journalStreamAdd(nodes, cell.nodes)
    }
    let proofParameters = [SqlParameter.Text(source.threadId), SqlParameter.Text(source.runId)]
    let suffix = " FROM audit_events WHERE thread_id=? AND run_id=? AND kind IN ('host_continuation_claim_consumed_v1','host_continuation_history_v1')"
    let records = tx.query("SELECT rowid" + suffix, proofParameters)
    if (records.size != 1) { throw IllegalStateException("continuation claim is absent or duplicated") }
    let proof = contextReadMetadataMeasureOwned(tx, "payload", " FROM audit_events WHERE rowid=?",
        [SqlParameter.Int64Value(journalStreamInteger(records[0].required(0)))], payment.owner,
        payment.extra173d(payment.rowPeak), current)
    bytes = journalStreamAdd(bytes, proof.bytes); nodes = journalStreamAdd(nodes, proof.nodes)
    // A consumed live-origin verifier additionally reads the immutable launch
    // budget and composition. A copied historical request does not require an
    // old composition that may have been legitimately retired afterwards.
    let origin = tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND kind='host_continuation_claim_consumed_v1'",
        proofParameters)
    if (journalStreamInteger(origin[0].required(0)) == 1) {
        let budget = contextReadMetadataMeasureOwned(tx, "budget", " FROM runs WHERE thread_id=? AND id=?", proofParameters,
            payment.owner, payment.extra173d(payment.rowPeak), current)
        let composition = contextReadMetadataMeasureOwned(tx, "payload", " FROM composition_snapshots WHERE id=?",
            [SqlParameter.Text("composition-" + source.runId)], payment.owner, payment.extra173d(payment.rowPeak), current)
        bytes = journalStreamAdd(bytes, journalStreamAdd(budget.bytes, composition.bytes))
        nodes = journalStreamAdd(nodes, journalStreamAdd(budget.nodes, composition.nodes))
    }
    payment.simultaneous173d(journalStreamAdd(1048576, journalStreamAdd(ownedThreadReadbackMultiply(bytes, 32),
        ownedThreadReadbackMultiply(nodes, 2048))))
    journalStreamCheck(current)
}

// Existing consumed/historical DATA proofs are rechecked both before and after
// every target/history/checkpoint trigger. The exact request remains local to
// this paid synchronous frame; no claim, continuation or Source is reminted.
func completedForkRequireContinuation173d(tx: SqliteTransaction, item: ThreadItem,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    let expected = if (isContinuationInitiatorDescription(item)) {
        item.provenance.continuationOrigin.getOrThrow().requestDigest }
        else { item.provenance.continuationHistory.getOrThrow().requestDigest }
    let source = ContinuationHistorySource(item.threadId.value, item.turnId.value,
        item.provenance.runId.getOrThrow().value, item.id.value, expected)
    completedForkPrepaySourceReference173d(tx, source, payment, current)
    let request = if (isContinuationInitiatorDescription(item)) { consumedContinuationRequest(tx, item) }
        else { continuationHistoryRequest(tx, item) }
    if (canonicalAgentValueSha256(request) != expected) {
        throw IllegalStateException("continuation history source input changed") }
    journalStreamCheck(current)
}

func completedForkCheckpointCopyFrame173d(tx: SqliteTransaction, source: ThreadId, target: ThreadId,
    sourceHeader: CompletedForkHeader173d, targetHeader: CompletedForkHeader173d, rowid: Int64, cover: Int64,
    sourceDigest: String, payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    // Compute the target prefix before retaining a complete source checkpoint.
    // No checkpoint DOM coexists with an unrelated complete Item decoder.
    let targetDigest = completedForkScan173d(tx, target, targetHeader, payment, current, cover)
    if (targetDigest == "checkpoint-splits-tool-round") { throw IllegalStateException("context checkpoint splits a canonical tool round") }
    let parameters = [SqlParameter.Int64Value(rowid), SqlParameter.Text(source.value)]
    let suffix = " FROM context_checkpoints WHERE rowid=? AND thread_id=?"
    let sizes = tx.query("SELECT length(CAST(id AS BLOB)),length(CAST(source_digest AS BLOB))," +
        "length(CAST(projector_version AS BLOB)),length(CAST(lane_compatibility AS BLOB))" + suffix, parameters)
    if (sizes.size != 1) { throw IllegalStateException("checkpoint identity changed") }
    var metadataBytes: Int64 = 0
    for (at in 0..4) { metadataBytes = journalStreamAdd(metadataBytes, journalStreamInteger(sizes[0].required(at))) }
    let extra = payment.extra173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(metadataBytes, 16)))
    let payload = contextReadMetadataMeasureOwned(tx, "payload", suffix, parameters, payment.owner, extra, current)
    // Original checkpoint decoder, note/artifact arrays, payload container,
    // indexed source/target digest and every original writer/SQL copy coexist.
    // Pay before the first complete SQL String/DOM is copied or constructed.
    payment.checkpointPeak = journalStreamAdd(4194304, journalStreamAdd(ownedThreadReadbackMultiply(metadataBytes, 32),
        journalStreamAdd(ownedThreadReadbackMultiply(payload.bytes, 12), ownedThreadReadbackMultiply(payload.nodes, 1024))))
    payment.transient173d(0)
    let rows = tx.query("SELECT id,covers_through_item_ordinal,projector_version,lane_compatibility,source_digest,payload" + suffix, parameters)
    if (rows.size != 1 || journalStreamInteger(rows[0].required(1)) != cover || rows[0].required(2) != "agent-product-v1" ||
        rows[0].required(3) != "agent-core" || rows[0].required(4) != sourceDigest || rows[0].required(5).size != payload.bytes) {
        throw IllegalStateException("checkpoint source changed inside its exact copy") }
    let meter = StoredValuePaymentMeter(rows[0].required(5), payment.owner, extraRetained: extra)
    if (meter.complete() != payload.nodes) { throw IllegalStateException("checkpoint grammar changed") }
    let original = decodeCheckpointPayload(rows[0].required(0), source, cover, sourceDigest,
        rows[0].required(2), rows[0].required(3), rows[0].required(5))
    // Keep the actual raw row/decoded checkpoint and add the complete original
    // target container/writer/readback SUM before any target encoding begins.
    payment.checkpointPeak = journalStreamAdd(4194304, journalStreamAdd(ownedThreadReadbackMultiply(metadataBytes, 32),
        journalStreamAdd(ownedThreadReadbackMultiply(payload.bytes, 14), ownedThreadReadbackMultiply(payload.nodes, 1024))))
    payment.transient173d(0)
    // Preserve the old fork recipe exactly: summary/goal/notes/artifacts are
    // historical DATA, whereas activeState deliberately uses the empty default.
    let checkpoint = ContextCheckpoint("checkpoint-" + target.value + "-" + cover.toString() + "-1", target,
        cover, original.structuredSummary, targetDigest, original.projectorVersion, original.laneCompatibility,
        activeGoal: original.activeGoal, durableNotes: original.durableNotes, artifactReferences: original.artifactReferences)
    match (validateStoredContextCheckpoint(checkpoint)) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
        case Result.Ok(_) => () }
    let encoded = encodeCheckpointPayload(checkpoint)
    if (encoded.size > 8388608) { throw IllegalArgumentException("checkpoint exceeds the durable codec boundary") }
    let created = agentUtcMillis()
    tx.execute("INSERT INTO context_checkpoints (id,thread_id,covers_through_item_ordinal,projector_version,lane_compatibility," +
        "source_digest,payload,created_at_millis) VALUES (?,?,?,?,?,?,?,?)",
        [SqlParameter.Text(checkpoint.id), SqlParameter.Text(target.value), SqlParameter.Int64Value(cover),
            SqlParameter.Text(checkpoint.projectorVersion), SqlParameter.Text(checkpoint.laneCompatibility),
            SqlParameter.Text(targetDigest), SqlParameter.Text(encoded), SqlParameter.Int64Value(created)])
    let copied = tx.query("SELECT COUNT(*) FROM context_checkpoints WHERE id=? AND thread_id=? " +
        "AND CAST(covers_through_item_ordinal AS TEXT)=? AND CAST(projector_version AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(lane_compatibility AS BLOB)=CAST(? AS BLOB) AND CAST(source_digest AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND CAST(created_at_millis AS TEXT)=?",
        [SqlParameter.Text(checkpoint.id), SqlParameter.Text(target.value), SqlParameter.Text(cover.toString()),
            SqlParameter.Text(checkpoint.projectorVersion), SqlParameter.Text(checkpoint.laneCompatibility),
            SqlParameter.Text(targetDigest), SqlParameter.Text(encoded), SqlParameter.Text(created.toString())])
    if (copied.size != 1 || journalStreamInteger(copied[0].required(0)) != 1) {
        throw IllegalStateException("checkpoint id already has different content") }
    let unchanged = tx.query("SELECT COUNT(*)" + suffix +
        " AND CAST(id AS BLOB)=CAST(? AS BLOB) AND CAST(covers_through_item_ordinal AS TEXT)=? " +
        "AND CAST(projector_version AS BLOB)=CAST(? AS BLOB) AND CAST(lane_compatibility AS BLOB)=CAST(? AS BLOB) " +
        "AND CAST(source_digest AS BLOB)=CAST(? AS BLOB) AND CAST(payload AS BLOB)=CAST(? AS BLOB)",
        [SqlParameter.Int64Value(rowid), SqlParameter.Text(source.value), SqlParameter.Text(rows[0].required(0)),
            SqlParameter.Text(rows[0].required(1)), SqlParameter.Text(rows[0].required(2)), SqlParameter.Text(rows[0].required(3)),
            SqlParameter.Text(rows[0].required(4)), SqlParameter.Text(rows[0].required(5))])
    if (unchanged.size != 1 || journalStreamInteger(unchanged[0].required(0)) != 1) {
        throw IllegalStateException("checkpoint source changed after its copy") }
    journalStreamCheck(current)
}

func completedForkCopyCheckpoint173d(tx: SqliteTransaction, source: ThreadId, target: ThreadId,
    sourceHeader: CompletedForkHeader173d, targetHeader: CompletedForkHeader173d,
    payment: CompletedForkPayment173d, current: () -> Result<Unit>): Unit {
    var offset: Int64 = 0
    while (true) {
        journalStreamCheck(current)
        // Preserve original covers DESC/id DESC precedence without retaining
        // every complete candidate payload in one query result array.
        let selected = tx.query("SELECT rowid,covers_through_item_ordinal FROM context_checkpoints WHERE thread_id=? " +
            "AND projector_version='agent-product-v1' AND lane_compatibility='agent-core' " +
            "ORDER BY covers_through_item_ordinal DESC,id DESC LIMIT 1 OFFSET ?",
            [SqlParameter.Text(source.value), SqlParameter.Int64Value(offset)])
        if (selected.isEmpty()) { return }
        if (selected.size != 1) { throw IllegalStateException("checkpoint identity is ambiguous") }
        offset++
        let cover = journalStreamInteger(selected[0].required(1))
        if (cover < 1 || cover >= sourceHeader.next) { continue }
        let rowid = journalStreamInteger(selected[0].required(0))
        let digest = completedForkScan173d(tx, source, sourceHeader, payment, current, cover)
        if (digest == "checkpoint-splits-tool-round") { continue }
        let parameters = [SqlParameter.Int64Value(rowid), SqlParameter.Text(source.value)]
        let sizes = tx.query("SELECT length(CAST(source_digest AS BLOB)) FROM context_checkpoints WHERE rowid=? AND thread_id=?", parameters)
        if (sizes.size != 1) { throw IllegalStateException("checkpoint identity changed") }
        payment.transient173d(journalStreamAdd(65536, ownedThreadReadbackMultiply(journalStreamInteger(sizes[0].required(0)), 16)))
        let expected = tx.query("SELECT source_digest FROM context_checkpoints WHERE rowid=? AND thread_id=?", parameters)
        if (expected.size != 1) { throw IllegalStateException("checkpoint identity changed") }
        if (expected[0].required(0) != digest) { continue }
        completedForkCheckpointCopyFrame173d(tx, source, target, sourceHeader, targetHeader, rowid, cover, digest, payment, current)
        // The SQL/DOM/encoder/digest helper and all copied candidate rows have
        // returned. This counter changes no actual owner reservation or ACK.
        payment.checkpointPeak = 0
        return
    }
}
