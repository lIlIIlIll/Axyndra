package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// A disposable data projection written AFTER the original canonical result.
// This transaction does not resolve an Operation, replace a model lane, grant
// Source, release physical custody, or alter a pending batch/continuation.
public class SqlitePostCanonicalCheckpointStore {
    private let database: SqliteDatabase
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    public init(database: SqliteDatabase, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.database = database; this.allocate = allocate
    }
    public func save(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        run: RunId, epoch: Int64, projection: InvocationContextProjection,
        toolSet: ?ToolSetSnapshot, toolName: String, expectedPlan: NormalizedOperationPlan, result: ToolResult,
        createdAtMillis: Int64, guard: () -> Result<Unit>): Result<Unit> {
        saveCurrent(checkpoint, expected, run, epoch, projection, toolSet, toolName,
            expectedPlan, result, createdAtMillis, guard, None<DirectPostCanonicalProjectionBoundary>)
    }
    public func saveDirect(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        projection: InvocationContextProjection, toolSet: ?ToolSetSnapshot, toolName: String,
        expectedPlan: NormalizedOperationPlan, result: ToolResult, createdAtMillis: Int64, boundary: DirectPostCanonicalProjectionBoundary,
        guard: () -> Result<Unit>): Result<Unit> {
        boundary.consume({ => saveCurrent(checkpoint, expected, boundary.source.runId,
            boundary.source.epoch, projection, toolSet, toolName, expectedPlan, result, createdAtMillis,
            guard, Some(boundary)) })
    }
    // Retained canonical DATA for an actually finished Run. This does not
    // recover/start a Run, replace its lane, mint Source, resolve an Operation
    // or release any execution custody. The full original plan/Receipt and
    // complete same-TX prefix/budget/record guards below remain mandatory.
    public func saveRetainedData173(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        run: RunId, epoch: Int64, projection: InvocationContextProjection,
        toolSet: ?ToolSetSnapshot, expectedPlan: NormalizedOperationPlan, result: ToolResult,
        createdAtMillis: Int64, guard: () -> Result<Unit>): Result<Unit> {
        saveCurrent(checkpoint, expected, run, epoch, projection, toolSet, expectedPlan.toolName,
            expectedPlan, result, createdAtMillis, guard, None<DirectPostCanonicalProjectionBoundary>, inactiveData173: true)
    }
    // The supplied opaque share is a synchronous borrow. Its actual producer
    // retains ownership until this complete Store/TX helper has returned.
    public func saveOwned185(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        run: RunId, epoch: Int64, projection: InvocationContextProjection,
        toolSet: SharedToolSetSnapshot159, toolName: String, expectedPlan: NormalizedOperationPlan, result: ToolResult,
        createdAtMillis: Int64, guard: () -> Result<Unit>): Result<Unit> {
        saveCurrent(checkpoint, expected, run, epoch, projection, None<ToolSetSnapshot>, toolName,
            expectedPlan, result, createdAtMillis, guard, None<DirectPostCanonicalProjectionBoundary>, ownedToolSet185: Some(toolSet))
    }
    public func saveDirectOwned185(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        projection: InvocationContextProjection, toolSet: SharedToolSetSnapshot159, toolName: String,
        expectedPlan: NormalizedOperationPlan, result: ToolResult, createdAtMillis: Int64, boundary: DirectPostCanonicalProjectionBoundary,
        guard: () -> Result<Unit>): Result<Unit> {
        boundary.consume({ => saveCurrent(checkpoint, expected, boundary.source.runId,
            boundary.source.epoch, projection, None<ToolSetSnapshot>, toolName, expectedPlan, result, createdAtMillis,
            guard, Some(boundary), ownedToolSet185: Some(toolSet)) })
    }
    public func saveRetainedOwned185(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        run: RunId, epoch: Int64, projection: InvocationContextProjection,
        toolSet: SharedToolSetSnapshot159, expectedPlan: NormalizedOperationPlan, result: ToolResult,
        createdAtMillis: Int64, guard: () -> Result<Unit>): Result<Unit> {
        saveCurrent(checkpoint, expected, run, epoch, projection, None<ToolSetSnapshot>, expectedPlan.toolName,
            expectedPlan, result, createdAtMillis, guard, None<DirectPostCanonicalProjectionBoundary>,
            inactiveData173: true, ownedToolSet185: Some(toolSet))
    }
    private func saveCurrent(checkpoint: ContextCheckpoint, expected: ThreadRecord,
        run: RunId, epoch: Int64, projection: InvocationContextProjection,
        toolSet: ?ToolSetSnapshot, toolName: String, expectedPlan: NormalizedOperationPlan, result: ToolResult,
        createdAtMillis: Int64, guard: () -> Result<Unit>,
        directBoundary: ?DirectPostCanonicalProjectionBoundary, inactiveData173!: Bool = false,
        ownedToolSet185!: ?SharedToolSetSnapshot159 = None): Result<Unit> {
        if (createdAtMillis < 0) { return checkpointStoreError("context.checkpoint_timestamp_invalid",
            "checkpoint timestamp must not be negative") }
        if (checkpoint.threadId.value != expected.id.value) {
            return checkpointStoreError("context.checkpoint_wrong_thread", "checkpoint belongs to another Thread") }
        if (epoch < 1 || expectedPlan.toolName != toolName || result.isError || result.receiptId == "" || result.payloadLease.isNone() ||
            checkpoint.coversThroughItemOrdinal < 1 || checkpoint.coversThroughItemOrdinal >= expected.nextItemOrdinal) {
            return checkpointStoreError("context.checkpoint_canonical_owner_missing",
                "post-canonical save requires the actual completed result and current invocation") }
        var paid: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
        try {
            let owner = allocate(65536); paid = Some(owner)
            // New wrapper/SQL state is prepaid; the original output/checkpoint
            // values remain held by their original consumer leases throughout.
            var headers: Int64 = 0
            for (size in [expected.id.value.size, run.value.size, result.callId.size,
                result.receiptId.size, toolName.size, checkpoint.id.size, checkpoint.sourceDigest.size,
                checkpoint.projectorVersion.size, checkpoint.laneCompatibility.size]) {
                headers = journalStreamAdd(headers, size) }
            let retained = journalStreamAdd(1048576, ownedThreadReadbackMultiply(headers, 8))
            owner.ensureRetainedPeak(retained)
            database.transaction<Unit> { tx: SqliteTransaction =>
                requirePostCanonicalCheckpointCurrent(tx, expected, run, epoch, projection, toolSet,
                    owner, retained, allocate, guard, directBoundary, inactiveData173: inactiveData173, ownedToolSet185: ownedToolSet185)
                let readback = PostCanonicalCheckpointReadback(tx, owner, retained)
                let boundary = PostCanonicalCheckpointBoundary(tx, expected, run, epoch,
                    checkpoint.coversThroughItemOrdinal, result, toolName, expectedPlan, owner, retained, allocate, guard,
                    match (directBoundary) { case Some(value) => Some(value.source); case None => None<DirectToolCallRef> })
                try {
                match (readback.visit(expected.id, expected.revision, 0, guard,
                    { item: ThreadItem, _: OwnedCanonicalThreadItemCustody => boundary.read(item) })) {
                    case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
                boundary.finish()
                requirePostCanonicalCheckpointReceipt(tx, expected, run, epoch, boundary.operation.getOrThrow(),
                    boundary.callItem.getOrThrow(), boundary.resultItem.getOrThrow(), result.receiptId, result.output,
                    owner, boundary.retainedPeak(), allocate, guard)
                let digest = match (ownedContextSourceDigest(expected, readback,
                    checkpoint.coversThroughItemOrdinal, guard)) {
                    case Result.Ok(value) => value; case Result.Err(error) => throw IllegalStateException(error.code) }
                if (digest != checkpoint.sourceDigest) {
                    throw IllegalStateException("checkpoint digest does not bind the complete current canonical prefix") }
                // All complete canonical Items were consumed inside this SAME
                // transaction. No corpus array or newest-N projection is made.
                postCanonicalCheckpointWrite(tx, checkpoint, createdAtMillis, owner,
                    boundary.retainedPeak(), guard)
                requirePostCanonicalCheckpointCurrent(tx, expected, run, epoch, projection, toolSet,
                    owner, boundary.retainedPeak(), allocate, guard, directBoundary, inactiveData173: inactiveData173, ownedToolSet185: ownedToolSet185)
                boundary.close()
                // A trigger on the disposable INSERT may mutate canonical
                // Items/plan/Receipt too. Re-read the COMPLETE window and
                // Source again in the same TX, after old captured IDs drop.
                requirePostCanonicalCheckpointWindow(tx, expected, run, epoch, checkpoint, result,
                    toolName, expectedPlan, owner, retained, allocate, guard,
                    match (directBoundary) { case Some(value) => Some(value.source); case None => None<DirectToolCallRef> })
                // A failing final guard THROWS, so the existing transaction
                // rolls back the INSERT. Returning Result.Err would commit.
                journalStreamCheck(guard)
                } finally { boundary.close() }
            }
            Result.Ok(())
        } catch (error: Exception) {
            checkpointStoreError("context.checkpoint_commit_failed",
                "post-canonical checkpoint projection did not reach a verified same-transaction save")
        } finally { match (paid) { case Some(value) => value.close(); case None => () } }
    }
}

private class PostCanonicalCheckpointReadback <: OwnedCanonicalThreadReadback {
    private let tx: SqliteTransaction
    private let owner: LogicalJsonOwnerReservation
    private let retained: Int64
    init(tx: SqliteTransaction, owner: LogicalJsonOwnerReservation, retained: Int64) {
        this.tx = tx; this.owner = owner; this.retained = retained }
    public func visit(thread: ThreadId, revision: Int64, afterOrdinal: Int64, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        let next = ownedThreadReadbackRevision(tx, thread, revision, guard)
        if (afterOrdinal < 0 || afterOrdinal >= next) {
            return ownedThreadReadbackFailure("thread.readback_cut_invalid") }
        var at = afterOrdinal + 1
        while (at < next) {
            owner.ensureRetainedPeak(retained)
            match (ownedThreadReadbackRow(tx, thread, revision, at, None<ItemId>, owner, guard, consume)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => at++ }
        }
        let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
        Result.Ok(())
    }
    public func visitItem(thread: ThreadId, revision: Int64, item: ItemId, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        let _ = ownedThreadReadbackRevision(tx, thread, revision, guard)
        let at = ownedThreadReadbackSelectedOrdinal(tx, thread, item)
        let answer = ownedThreadReadbackRow(tx, thread, revision, at, Some(item), owner, guard, consume)
        let _ = ownedThreadReadbackRevision(tx, thread, revision, guard); answer
    }
}

// Exact original validateCanonicalToolPairs order, including its checks AFTER
// the cover. IDs are independently copied under the same retained owner before
// the complete per-cell custody is ACKed; no decoded row backing escapes.
private class PostCanonicalCheckpointBoundary {
    private let tx: SqliteTransaction
    private let thread: ThreadRecord
    private let run: RunId
    private let epoch: Int64
    private let cover: Int64
    private let result: ToolResult
    private let tool: String
    private let expectedPlan: NormalizedOperationPlan
    private let owner: LogicalJsonOwnerReservation
    private let base: Int64
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    private let guard: () -> Result<Unit>
    private let direct: ?DirectToolCallRef
    private let pending = ArrayList<PostCanonicalCheckpointCopiedId>()
    private let retainedIds = ArrayList<PostCanonicalCheckpointCopiedId>()
    var operation: ?OperationId = None<OperationId>
    var callItem: ?ItemId = None<ItemId>
    var resultItem: ?ItemId = None<ItemId>
    init(tx: SqliteTransaction, thread: ThreadRecord, run: RunId, epoch: Int64, cover: Int64,
        result: ToolResult, tool: String, expectedPlan: NormalizedOperationPlan, owner: LogicalJsonOwnerReservation, base: Int64,
        allocate: (Int64) -> LogicalJsonOwnerReservation, guard: () -> Result<Unit>, direct: ?DirectToolCallRef) {
        this.direct = direct; this.expectedPlan = expectedPlan
        this.tx = tx; this.thread = thread; this.run = run; this.epoch = epoch
        this.cover = cover; this.result = result; this.tool = tool; this.owner = owner; this.base = base
        this.allocate = allocate; this.guard = guard }
    func retainedPeak(): Int64 { base }
    private func copy(value: String): String {
        let captured = PostCanonicalCheckpointCopiedId(value, owner)
        try { retainedIds.add(captured); captured.value.getOrThrow() }
        catch (error: Exception) { captured.close(); throw error }
    }
    func read(item: ThreadItem): Result<Unit> {
        match (item.content) {
            case ThreadItemContent.ToolCall(id, name, arguments) =>
                for (value in pending where value.value.getOrThrow() == id.value) {
                    return checkpointPairFailure("context.canonical_tool_protocol_incomplete", "duplicate canonical tool-call id") }
                let captured = PostCanonicalCheckpointCopiedId(id.value, owner)
                try { pending.add(captured) } catch (error: Exception) { captured.close(); throw error }
                if (id.value == result.callId) {
                    if (callItem.isSome() || name != tool) { throw IllegalStateException("canonical result has an ambiguous or different call") }
                    match (direct) { case Some(source) =>
                        match (effectiveDirectCallOrigin(item.provenance)) { case DirectCallOrigin.UserDirect => ()
                            case _ => throw IllegalStateException("checkpoint Direct origin changed") }
                        if (source.canonicalItemId.value != item.id.value || source.operationId.value != item.provenance.operationId.getOrThrow().value ||
                            source.threadId.value != item.threadId.value || source.turnId.value != item.turnId.value ||
                            source.runId.value != run.value || source.epoch != epoch || item.provenance.source != "direct_tool" ||
                            item.provenance.runId.getOrThrow().value != run.value || source.call.callId != id.value ||
                            source.call.name != name || !canonicalAgentValuesEqual(source.call.arguments, arguments)) {
                            throw IllegalStateException("checkpoint Direct full canonical call differs from the actual boundary") }
                        case None => () }
                    requirePostCanonicalCheckpointCall(tx, thread, run, epoch, item, arguments, tool, expectedPlan,
                        owner, base, allocate, guard)
                    callItem = Some(ItemId(copy(item.id.value))) }
            case ThreadItemContent.ToolResult(id, op, receipt, output, failed) =>
                var index: Int64 = -1
                for (at in 0..pending.size where pending[at].value.getOrThrow() == id.value) { index = at; break }
                if (index < 0) { return checkpointPairFailure("context.canonical_tool_protocol_incomplete",
                    "tool result has no preceding canonical tool call") }
                let released = pending[index]; pending.remove(at: index); released.close()
                if (id.value == result.callId) {
                    if (resultItem.isSome() || failed || item.ordinal != cover || receipt != result.receiptId ||
                        !canonicalAgentValuesEqual(output, result.output)) {
                        throw IllegalStateException("checkpoint does not cover its actual complete canonical result") }
                    operation = Some(OperationId(copy(op.value))); resultItem = Some(ItemId(copy(item.id.value))) }
            case _ => if (!pending.isEmpty()) { return checkpointPairFailure("context.canonical_tool_protocol_incomplete",
                "canonical tool round is split by another semantic Item") }
        }
        if (item.ordinal == cover && !pending.isEmpty()) {
            return checkpointPairFailure("context.checkpoint_splits_tool_round",
                "context checkpoint cannot split a canonical tool call/result round") }
        Result.Ok(())
    }
    func finish(): Unit {
        if (!pending.isEmpty() || operation.isNone() || callItem.isNone() || resultItem.isNone()) {
            throw IllegalStateException("canonical history is incomplete or does not contain the actual result") }
    }
    func close(): Unit {
        operation = None<OperationId>; callItem = None<ItemId>; resultItem = None<ItemId>
        for (value in pending) { value.close() }; pending.clear()
        for (value in retainedIds) { value.close() }; retainedIds.clear()
    }
}
// Each independent copied ID has one real child share of the original ledger.
// A settled pair drops its backing before that share closes; history does not
// accumulate an invoice for identifiers which the scanner no longer retains.
private class PostCanonicalCheckpointCopiedId {
    private let payment: LogicalJsonOwnerReservation
    var value: ?String = None<String>
    init(original: String, parent: LogicalJsonOwnerReservation) {
        this.payment = parent.deriveRetainedLease()
        try {
            payment.ensureRetainedPeak(journalStreamAdd(512, ownedThreadReadbackMultiply(original.size, 8)))
            value = Some(String.fromUtf8(original.toArray()))
        } catch (error: Exception) { payment.close(); throw error }
    }
    func close(): Unit { value = None<String>; payment.close() }
}
private func checkpointPairFailure(code: String, message: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message)) }

private func requirePostCanonicalCheckpointCurrent(tx: SqliteTransaction, thread: ThreadRecord, run: RunId,
    epoch: Int64, projection: InvocationContextProjection, toolSet: ?ToolSetSnapshot,
    owner: LogicalJsonOwnerReservation, retained: Int64, allocate: (Int64) -> LogicalJsonOwnerReservation,
    guard: () -> Result<Unit>, directBoundary: ?DirectPostCanonicalProjectionBoundary,
    inactiveData173!: Bool = false, ownedToolSet185!: ?SharedToolSetSnapshot159 = None): Unit {
    journalStreamCheck(guard)
    let parameters = [SqlParameter.Text(thread.id.value), SqlParameter.Int64Value(thread.revision),
        SqlParameter.Int64Value(thread.nextItemOrdinal), SqlParameter.Text(run.value), SqlParameter.Int64Value(epoch)]
    let identity = " FROM threads t JOIN runs r ON r.thread_id=t.id JOIN turns turn ON turn.id=r.turn_id " +
        "AND turn.thread_id=t.id WHERE t.id=? AND t.revision=? AND t.next_item_ordinal=? " +
        "AND r.id=? AND r.epoch=? "
    let state = if (inactiveData173) {
        "AND t.active_turn_id IS NULL AND r.finished_at_millis IS NOT NULL " +
            "AND r.state IN ('completed','failed','cancelled','recovery_required') AND turn.active_run_id IS NULL " +
            "AND turn.state!='active'"
    } else {
        "AND t.status='open' AND r.state='running' AND r.finished_at_millis IS NULL " +
            "AND t.active_turn_id=r.turn_id AND turn.active_run_id=r.id AND turn.state='active'" }
    if (tx.query("SELECT 1" + identity + state, parameters).size != 1 ||
        (inactiveData173 && (thread.activeTurnId.isSome() || directBoundary.isSome())) ||
        (!inactiveData173 && thread.activeTurnId.isNone())) {
        throw IllegalStateException("checkpoint lost actual current Run/Thread ownership") }
    if (inactiveData173) {
        // Numeric extent is read BEFORE the retained original turn identity.
        // Its real SQL/UTF8 backing stays in this paid helper frame only.
        let lengths = tx.query("SELECT length(CAST(r.turn_id AS BLOB))" + identity + state, parameters)
        if (lengths.size != 1) { throw IllegalStateException("retained canonical Run turn is absent") }
        let bytes = journalStreamInteger(lengths[0].required(0))
        let turnPeak = journalStreamAdd(retained, journalStreamAdd(1048576, ownedThreadReadbackMultiply(bytes, 8)))
        owner.ensureRetainedPeak(turnPeak)
        let turns = tx.query("SELECT r.turn_id" + identity + state, parameters)
        if (turns.size != 1 || turns[0].required(0).size != bytes) { throw IllegalStateException("retained canonical Run turn changed") }
        requirePostCanonicalCheckpointOrigin(tx, thread.id, SemanticTurnId(turns[0].required(0)), run, epoch, owner, turnPeak, guard)
    } else {
        requirePostCanonicalCheckpointOrigin(tx, thread.id, thread.activeTurnId.getOrThrow(), run,
            epoch, owner, retained, guard) }
    let suffix = " FROM runs WHERE id=? AND thread_id=? AND epoch=?" +
        (if (inactiveData173) { " AND finished_at_millis IS NOT NULL AND state IN ('completed','failed','cancelled','recovery_required')" }
        else { " AND state='running'" })
    let args = [SqlParameter.Text(run.value), SqlParameter.Text(thread.id.value), SqlParameter.Int64Value(epoch)]
    withLivePolicyStoredValueOwned(tx, "skill_snapshot", suffix, args, allocate, guard, owner, retained, { raw: String =>
        if (!postCanonicalCheckpointContextMatches(decodeStoredValue(raw), projection)) {
            throw IllegalStateException("checkpoint current context projection changed") } })
    match (ownedToolSet185) {
        case Some(expected) =>
            if (toolSet.isSome()) { throw IllegalStateException("checkpoint cannot mix owned and historical snapshots") }
            withLivePolicyStoredValueOwned(tx, "lane_snapshot", suffix, args, allocate, guard, owner, retained, { raw: String =>
                if (!expected.matchesStoredModelLane185(decodeStoredValue(raw))) {
                    throw IllegalStateException("checkpoint actual full frozen tool set changed") } })
        case None =>
    match (toolSet) { case Some(expected) =>
        withLivePolicyStoredValueOwned(tx, "lane_snapshot", suffix, args, allocate, guard, owner, retained, { raw: String =>
            if (!postCanonicalCheckpointToolSetMatches(decodeStoredValue(raw), expected)) {
                throw IllegalStateException("checkpoint actual full frozen tool set changed") } })
        case None => throw IllegalStateException("checkpoint has no actual frozen tool set") }
    }
    match (directBoundary) {
        case Some(boundary) =>
            requirePostCanonicalCheckpointDirectBudget(tx, thread, run, epoch, boundary, owner, retained, allocate, guard)
            return
        case None => () }
    // The current durable event is accounting evidence ONLY. It cannot grant
    // the canonical result or a new execution; original JSON decoder/envelope
    // and complete usage are checked again by the existing kernel validator.
    let budgetRows = tx.query("SELECT length(CAST(payload AS BLOB)) FROM app_run_events WHERE run_id=? " +
        "AND json_valid(payload)=1 AND json_extract(payload,'$.payload_type')='budget_updated' ORDER BY sequence DESC LIMIT 1",
        [SqlParameter.Text(run.value)])
    if (budgetRows.size != 1 || journalStreamInteger(budgetRows[0].required(0)) > 8192) {
        throw IllegalStateException("checkpoint current canonical budget event is missing") }
    owner.ensureRetainedPeak(journalStreamAdd(retained, 1048576))
    let events = tx.query("SELECT payload FROM app_run_events WHERE run_id=? AND json_valid(payload)=1 " +
        "AND json_extract(payload,'$.payload_type')='budget_updated' ORDER BY sequence DESC LIMIT 1", [SqlParameter.Text(run.value)])
    if (events.size != 1 || events[0].required(0).size != journalStreamInteger(budgetRows[0].required(0))) {
        throw IllegalStateException("checkpoint accounting event extent changed") }
    let event = decodeAgentValue(events[0].required(0), maxBytes: 8192).value().getOrThrow()
    requireContextBoundaryBudget(tx, run, event.field("detail").getOrThrow())
    journalStreamCheck(guard)
}

// Prepay every complete cell reached by the ORIGINAL continuation validator,
// including its initial immutable composition. A User initiator needs only
// the original kind check; a consumed continuation keeps all existing Source,
// origin/claim/request/launch/budget/composition checks inside the same TX.
// The numeric selector does not first copy an unbounded malformed kind field.
private func requirePostCanonicalCheckpointOrigin(tx: SqliteTransaction, thread: ThreadId,
    turn: SemanticTurnId, run: RunId, epoch: Int64, owner: LogicalJsonOwnerReservation,
    retained: Int64, guard: () -> Result<Unit>): Unit {
    journalStreamCheck(guard)
    let suffix = " FROM runs r JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id " +
        "JOIN items i ON i.id=t.user_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id " +
        "WHERE r.id=? AND r.thread_id=? AND r.turn_id=? AND r.epoch=?"
    let args = [SqlParameter.Text(run.value), SqlParameter.Text(thread.value),
        SqlParameter.Text(turn.value), SqlParameter.Int64Value(epoch)]
    let selected = tx.query("SELECT CASE WHEN i.kind='user_message' THEN 1 " +
        "WHEN i.kind='system_note' THEN 2 ELSE 0 END" + suffix, args)
    if (selected.size != 1) { throw IllegalStateException("checkpoint canonical initiator is missing") }
    let kind = journalStreamInteger(selected[0].required(0))
    if (kind == 1) {
        requireUserOrConsumedContinuation(tx, thread, turn, run, epoch)
        journalStreamCheck(guard); return
    }
    if (kind != 2) { throw IllegalStateException("checkpoint has no original canonical initiator kind") }
    var bytes: Int64 = 0
    var nodes: Int64 = 0
    for (column in ["i.payload", "i.provenance", "r.budget"]) {
        let cell = contextReadMetadataMeasureOwned(tx, column, suffix, args, owner, retained, guard)
        bytes = journalStreamAdd(bytes, cell.bytes); nodes = journalStreamAdd(nodes, cell.nodes)
    }
    let claim = contextReadMetadataMeasureOwned(tx, "payload",
        " FROM audit_events WHERE thread_id=? AND run_id=? AND kind='host_continuation_claim_consumed_v1'",
        [SqlParameter.Text(thread.value), SqlParameter.Text(run.value)], owner, retained, guard)
    bytes = journalStreamAdd(bytes, claim.bytes); nodes = journalStreamAdd(nodes, claim.nodes)
    let compositionId = "composition-" + run.value
    let composition = contextReadMetadataMeasureOwned(tx, "payload",
        " FROM composition_snapshots WHERE id=?", [SqlParameter.Text(compositionId)], owner, retained, guard)
    bytes = journalStreamAdd(bytes, composition.bytes); nodes = journalStreamAdd(nodes, composition.nodes)
    let headers = tx.query("SELECT length(CAST(i.id AS BLOB))" + suffix, args)
    let digests = tx.query("SELECT length(CAST(digest AS BLOB)) FROM composition_snapshots WHERE id=?",
        [SqlParameter.Text(compositionId)])
    if (headers.size != 1 || digests.size != 1) {
        throw IllegalStateException("checkpoint continuation metadata is not unique") }
    bytes = journalStreamAdd(bytes, journalStreamInteger(headers[0].required(0)))
    bytes = journalStreamAdd(bytes, journalStreamInteger(digests[0].required(0)))
    owner.ensureRetainedPeak(journalStreamAdd(retained, contextReadMetadataPeak(bytes, nodes)))
    // No decoded value escapes this original validation call or becomes a
    // new admission. The borrowed actual owner is neither closed nor refunded.
    requireUserOrConsumedContinuation(tx, thread, turn, run, epoch)
    journalStreamCheck(guard)
}

// This is a comparison of DATA inside the already paid original StoredValue
// cell. It does not construct a second complete snapshot/JSON String or mint
// Source. The original context codec's fields, list order, trust spelling,
// optional expiry, UTF-8 byte/JSON boundary and all digests remain checked.
func postCanonicalCheckpointContextMatches(value: AgentValue, expected: InvocationContextProjection): Bool {
    if (!httpIntentExactFields(value, ["schema", "source_digest", "contributions"]) ||
        postCanonicalCheckpointText(value, "schema") != RUN_CONTEXT_SNAPSHOT_SCHEMA ||
        postCanonicalCheckpointText(value, "source_digest") != expected.sourceDigest ||
        postCanonicalCheckpointJsonBytes(value) > RUN_CONTEXT_SNAPSHOT_MAX_BYTES) { return false }
    let actual = value.field("contributions").getOrThrow()
    let contributions = expected.contributions()
    if (actual.unifiedKind != ValueKind.List || actual.items.size != contributions.size || contributions.size > 1024) { return false }
    var references: Int64 = 0
    var retainedBytes: Int64 = 0
    for (at in 0..contributions.size) {
        let item = actual.items[at]; let wanted = contributions[at]
        let names = if (wanted.validUntilMillis > 0) {
            ["owner", "id", "source_ref", "content", "content_digest", "trust", "references", "valid_until_millis"]
        } else { ["owner", "id", "source_ref", "content", "content_digest", "trust", "references"] }
        if (!httpIntentExactFields(item, names) || postCanonicalCheckpointText(item, "owner") != wanted.owner ||
            postCanonicalCheckpointText(item, "id") != wanted.id || postCanonicalCheckpointText(item, "source_ref") != wanted.sourceRef ||
            postCanonicalCheckpointText(item, "content") != wanted.content ||
            postCanonicalCheckpointText(item, "content_digest") != modelPolicySha256Text(wanted.content) ||
            postCanonicalCheckpointText(item, "trust") != postCanonicalCheckpointTrustName(wanted.trust)) { return false }
        if (wanted.validUntilMillis > 0) {
            let expiry = item.field("valid_until_millis").getOrThrow()
            if (expiry.unifiedKind != ValueKind.Number || expiry.asNumberText() != wanted.validUntilMillis.toString()) { return false } }
        for (size in [wanted.owner.size, wanted.id.size, wanted.sourceRef.size, wanted.content.size]) {
            retainedBytes = journalStreamAdd(retainedBytes, size) }
        let refs = item.field("references").getOrThrow(); let desired = wanted.references()
        if (refs.unifiedKind != ValueKind.List || refs.items.size != desired.size) { return false }
        references = journalStreamAdd(references, desired.size)
        if (references > 4096) { return false }
        for (index in 0..desired.size) {
            let ref = refs.items[index]; let target = desired[index]
            if (!httpIntentExactFields(ref, ["id", "locator", "trust", "content", "content_digest"]) ||
                postCanonicalCheckpointText(ref, "id") != target.id || postCanonicalCheckpointText(ref, "locator") != target.locator ||
                postCanonicalCheckpointText(ref, "trust") != postCanonicalCheckpointTrustName(target.trust)) { return false }
            let content = ref.field("content").getOrThrow(); let digest = ref.field("content_digest").getOrThrow()
            retainedBytes = journalStreamAdd(retainedBytes, journalStreamAdd(target.id.size, target.locator.size))
            match (target.content) {
                case Some(text) =>
                    if (content.unifiedKind != ValueKind.Text || content.text != text || digest.unifiedKind != ValueKind.Text ||
                        target.contentDigest.isNone() || digest.text != target.contentDigest.getOrThrow() ||
                        digest.text != modelPolicySha256Text(text)) { return false }
                    retainedBytes = journalStreamAdd(retainedBytes, text.size)
                case None => if (content.unifiedKind != ValueKind.Null || digest.unifiedKind != ValueKind.Null || target.contentDigest.isSome()) { return false } }
        }
        if (retainedBytes > RUN_CONTEXT_SNAPSHOT_MAX_BYTES) { return false }
    }
    true
}
private func postCanonicalCheckpointTrustName(value: ContextContentTrust): String {
    match (value) { case ContextContentTrust.UserSelected => "user_selected"; case ContextContentTrust.UntrustedData => "untrusted_data" } }

// Exact compact/default yjson UTF-8 byte count for this closed snapshot codec.
// The whole StoredValue decoder/payment already checked grammar/EOF/depth and
// paid scalar byte copies; no JSON output, alternate field order or substring
// is retained. Numeric expiry above must retain the original integer spelling.
private func postCanonicalCheckpointQuotedBytes(text: String): Int64 {
    var size: Int64 = 2
    for (byte in text.toArray()) {
        size = journalStreamAdd(size, if (byte == b'"' || byte == b'\\' ||
            byte == 8 || byte == 9 || byte == 10 || byte == 12 || byte == 13) { 2 }
            else if (byte < 32) { 6 } else { 1 }) }
    size
}
private func postCanonicalCheckpointJsonBytes(value: AgentValue): Int64 {
    match (value.unifiedKind) {
        case ValueKind.Null => 4
        case ValueKind.Boolean => if (value.asBool()) { 4 } else { 5 }
        case ValueKind.Text => postCanonicalCheckpointQuotedBytes(value.text)
        case ValueKind.Number => value.asNumberText().size
        case ValueKind.List =>
            var size: Int64 = 2; var first = true
            for (item in value.items) {
                if (!first) { size = journalStreamAdd(size, 1) }; first = false
                size = journalStreamAdd(size, postCanonicalCheckpointJsonBytes(item)) }; size
        case ValueKind.Object =>
            var size: Int64 = 2; var first = true
            for (field in value.fields) {
                if (!first) { size = journalStreamAdd(size, 1) }; first = false
                size = journalStreamAdd(size, journalStreamAdd(1, postCanonicalCheckpointQuotedBytes(field.name)))
                size = journalStreamAdd(size, postCanonicalCheckpointJsonBytes(field.value)) }; size
    }
}

// Compare every immutable tool identity/schema/capability/hook field using the
// original model-lane decoder's optional defaults. A same-id substituted tool
// set cannot establish current invocation identity. No canonical serialization
// of a second full schema/catalog is allocated here.
func postCanonicalCheckpointToolSetMatches(lane: AgentValue, expected: ToolSetSnapshot): Bool {
    if (postCanonicalCheckpointText(lane, "tool_set_id").trimAscii() != expected.id) { return false }
    match (expected.threadId) {
        case Some(id) => if (postCanonicalCheckpointText(lane, "tool_set_thread_id") != id.value) { return false }
        case None => if (lane.field("tool_set_thread_id").isSome()) { return false } }
    let tools = lane.field("tools").getOrThrow()
    if (tools.unifiedKind != ValueKind.List || tools.items.size != expected.entries.size) { return false }
    for (at in 0..expected.entries.size) {
        let actual = tools.items[at]; let wanted = expected.entries[at]
        if (postCanonicalCheckpointText(actual, "name").trimAscii() != wanted.name || postCanonicalCheckpointText(actual, "description") != wanted.description ||
            postCanonicalCheckpointText(actual, "executor_version").trimAscii() != wanted.executorVersion ||
            postCanonicalCheckpointOptionalText(actual, "implementation_fingerprint").trimAscii() != wanted.implementationFingerprint ||
            postCanonicalCheckpointOptionalText(actual, "schema_digest") != wanted.schemaDigest ||
            postCanonicalCheckpointOptionalBool(actual, "available_at_snapshot") != wanted.availableAtSnapshot ||
            !canonicalAgentValuesEqual(actual.field("input_schema").getOrThrow(), wanted.inputSchema)) { return false }
        let caps = actual.field("capabilities").getOrThrow()
        if (caps.unifiedKind != ValueKind.List || caps.items.size != wanted.requiredCapabilities.size) { return false }
        for (index in 0..wanted.requiredCapabilities.size) {
            if (postCanonicalCheckpointText(caps.items[index], "kind") != postCanonicalCheckpointCapabilityName(wanted.requiredCapabilities[index].kind) ||
                postCanonicalCheckpointText(caps.items[index], "resource") != wanted.requiredCapabilities[index].resource) { return false } }
    }
    match (lane.field("hooks")) {
        case None => if (!expected.hookHandlers.isEmpty()) { return false }
        case Some(hooks) =>
            if (hooks.unifiedKind != ValueKind.List || hooks.items.size != expected.hookHandlers.size) { return false }
            for (at in 0..expected.hookHandlers.size) {
                let actual = hooks.items[at]; let wanted = expected.hookHandlers[at]
                if (postCanonicalCheckpointText(actual, "event") != wanted.event ||
                    postCanonicalCheckpointText(actual, "plugin_id").trimAscii() != wanted.pluginId ||
                    postCanonicalCheckpointText(actual, "plugin_version").trimAscii() != wanted.pluginVersion ||
                    postCanonicalCheckpointText(actual, "content_digest").trimAscii() != wanted.contentDigest ||
                    postCanonicalCheckpointText(actual, "package_root").trimAscii() != wanted.packageRoot ||
                    postCanonicalCheckpointText(actual, "matcher").trimAscii() != wanted.matcher ||
                    postCanonicalCheckpointText(actual, "command") != wanted.command ||
                    postCanonicalCheckpointInteger(actual, "timeout_millis") != wanted.timeoutMillis) { return false } }
    }
    true
}
private func postCanonicalCheckpointOptionalText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case None => ""
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text }
            else { throw IllegalStateException("frozen tool text field changed kind") } }
}
private func postCanonicalCheckpointText(value: AgentValue, name: String): String {
    let item = value.field(name).getOrThrow()
    if (item.unifiedKind != ValueKind.Text) { throw IllegalStateException("frozen snapshot text field changed kind") }
    item.text
}
private func postCanonicalCheckpointInteger(value: AgentValue, name: String): Int64 {
    let item = value.field(name).getOrThrow()
    if (item.unifiedKind != ValueKind.Number) { throw IllegalStateException("frozen snapshot integer field changed kind") }
    Int64.parse(item.asNumberText())
}
private func postCanonicalCheckpointOptionalBool(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case None => true
        case Some(item) => if (item.unifiedKind == ValueKind.Boolean) { item.asBool() }
            else { throw IllegalStateException("frozen tool bool field changed kind") } }
}
private func postCanonicalCheckpointCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"; case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"; case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.PeerMessage => "peer_message"; case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke" }
}

private func requirePostCanonicalCheckpointCall(tx: SqliteTransaction, thread: ThreadRecord, run: RunId,
    epoch: Int64, item: ThreadItem, arguments: AgentValue, tool: String, expectedPlan: NormalizedOperationPlan, owner: LogicalJsonOwnerReservation,
    retained: Int64, allocate: (Int64) -> LogicalJsonOwnerReservation, guard: () -> Result<Unit>): Unit {
    let args = [SqlParameter.Text(run.value), SqlParameter.Text(item.id.value),
        SqlParameter.Text(thread.id.value), SqlParameter.Int64Value(epoch)]
    let suffix = " FROM operations o JOIN runs r ON r.id=o.run_id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id " +
        "AND e.tool_call_item_id=o.tool_call_item_id AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) " +
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
        "WHERE o.run_id=? AND o.tool_call_item_id=? AND r.thread_id=? AND r.epoch=? " +
        "AND o.state='committed' AND receipt.outcome='completed' " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)"
    if (tx.query("SELECT 1" + suffix, args).size != 1) { throw IllegalStateException("checkpoint call lacks its actual committed Root") }
    withPostCanonicalCheckpointExpectedPlan(expectedPlan, owner, retained, guard, { original: AgentValue, expectedPeak: Int64 =>
        withLivePolicyStoredValueOwned(tx, "o.normalized_plan", suffix, args, allocate, guard, owner, expectedPeak, { raw: String =>
            let actual = decodeStoredValue(raw)
            if (expectedPlan.toolName != tool || !canonicalAgentValuesEqual(expectedPlan.canonicalArguments, arguments) ||
                !canonicalAgentValuesEqual(actual, original)) {
                throw IllegalStateException("checkpoint whole frozen operation plan differs from the original invocation") } }) })
}

private func requirePostCanonicalCheckpointReceipt(tx: SqliteTransaction, thread: ThreadRecord, run: RunId,
    epoch: Int64, operation: OperationId, call: ItemId, result: ItemId, receipt: String, expectedOutput: AgentValue,
    owner: LogicalJsonOwnerReservation, retained: Int64, allocate: (Int64) -> LogicalJsonOwnerReservation,
    guard: () -> Result<Unit>): Unit {
    let args = [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(call.value),
        SqlParameter.Text(result.value), SqlParameter.Text(receipt), SqlParameter.Text(thread.id.value), SqlParameter.Int64Value(epoch)]
    let suffix = " FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id " +
        "AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.kind='tool_call' " +
        "JOIN items result ON result.id=e.reserved_result_item_id AND result.kind='tool_result' " +
        "JOIN runs r ON r.id=o.run_id WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? " +
        "AND result.id=? AND receipt.id=? AND r.thread_id=? AND r.epoch=? AND o.state='committed' " +
        "AND receipt.outcome='completed' AND call.thread_id=r.thread_id AND result.thread_id=r.thread_id " +
        "AND call.turn_id=r.turn_id AND result.turn_id=r.turn_id " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)"
    if (tx.query("SELECT 1" + suffix, args).size != 1) {
        throw IllegalStateException("checkpoint result lacks its actual unique committed Root/Receipt/reserved Item") }
    withLivePolicyStoredValueOwned(tx, "receipt.detail", suffix, args, allocate, guard, owner, retained, { raw: String =>
        if (!canonicalAgentValuesEqual(decodeStoredValue(raw), expectedOutput)) {
            throw IllegalStateException("checkpoint Receipt detail differs from the original completed output") } })
    withLivePolicyStoredValueOwned(tx, "receipt.verification", suffix, args, allocate, guard, owner, retained, { raw: String =>
        let value = decodeStoredValue(raw)
        if (!httpIntentExactFields(value, ["known_completion", "stage"]) ||
            value.field("known_completion").getOrThrow().unifiedKind != ValueKind.Boolean ||
            !value.field("known_completion").getOrThrow().asBool() || postCanonicalCheckpointText(value, "stage") != "executing") {
            throw IllegalStateException("checkpoint requires the original known executing completion") } })
}

private func postCanonicalCheckpointWrite(tx: SqliteTransaction, checkpoint: ContextCheckpoint,
    at: Int64, owner: LogicalJsonOwnerReservation, retained: Int64, guard: () -> Result<Unit>): Unit {
    let wrappers = journalStreamAdd(16, journalStreamAdd(checkpoint.durableNotes.size, checkpoint.artifactReferences.size))
    let wrapperPeak = journalStreamAdd(1048576, ownedThreadReadbackMultiply(wrappers, 512))
    owner.ensureRetainedPeak(journalStreamAdd(retained, wrapperPeak))
    let value = checkpointPayloadValue(checkpoint); let extent = livePolicyStoredExtent(value)
    if (extent.bytes > 8388608) { throw IllegalStateException("checkpoint payload exceeds the original durable decoder bound") }
    // Includes encodeStoredValue buffer/Array/String plus SQLite bound text,
    // CAST/record copies; incoming summary/provenance is separately retained.
    owner.ensureRetainedPeak(journalStreamAdd(retained, journalStreamAdd(4194304,
        journalStreamAdd(ownedThreadReadbackMultiply(extent.bytes, 12), ownedThreadReadbackMultiply(extent.nodes, 512)))))
    match (validateStoredContextCheckpoint(checkpoint)) {
        case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
    let payload = encodeCheckpointPayload(checkpoint)
    if (payload.size != extent.bytes) { throw IllegalStateException("original checkpoint codec measurement drift") }
    journalStreamCheck(guard)
    let params = [SqlParameter.Text(checkpoint.id), SqlParameter.Text(checkpoint.threadId.value),
        SqlParameter.Int64Value(checkpoint.coversThroughItemOrdinal), SqlParameter.Text(checkpoint.projectorVersion),
        SqlParameter.Text(checkpoint.laneCompatibility), SqlParameter.Text(checkpoint.sourceDigest), SqlParameter.Text(payload)]
    let existing = tx.query("SELECT 1 FROM context_checkpoints WHERE id=? AND thread_id=? AND covers_through_item_ordinal=? " +
        "AND projector_version=? AND lane_compatibility=? AND source_digest=? AND CAST(payload AS BLOB)=CAST(? AS BLOB)", params)
    let count = tx.query("SELECT COUNT(*) FROM context_checkpoints WHERE id=?", [SqlParameter.Text(checkpoint.id)])
    if (count.size != 1) { throw IllegalStateException("checkpoint identity count is absent") }
    if (journalStreamInteger(count[0].required(0)) == 0) {
        tx.execute("INSERT INTO context_checkpoints(id,thread_id,covers_through_item_ordinal,projector_version," +
            "lane_compatibility,source_digest,payload,created_at_millis) VALUES (?,?,?,?,?,?,?,?)",
            [SqlParameter.Text(checkpoint.id), SqlParameter.Text(checkpoint.threadId.value),
                SqlParameter.Int64Value(checkpoint.coversThroughItemOrdinal), SqlParameter.Text(checkpoint.projectorVersion),
                SqlParameter.Text(checkpoint.laneCompatibility), SqlParameter.Text(checkpoint.sourceDigest),
                SqlParameter.Text(payload), SqlParameter.Int64Value(at)])
    } else if (existing.size != 1) { throw IllegalStateException("checkpoint id already has different content") }
    // A real SQLite trigger can change the row during INSERT. The same
    // transaction must prove the written projection still equals the complete
    // original codec, including its exact cover and canonical source digest.
    if (tx.query("SELECT 1 FROM context_checkpoints WHERE id=? AND thread_id=? AND covers_through_item_ordinal=? " +
        "AND projector_version=? AND lane_compatibility=? AND source_digest=? AND CAST(payload AS BLOB)=CAST(? AS BLOB)", params).size != 1) {
        throw IllegalStateException("checkpoint projection changed during its actual write") }
    journalStreamCheck(guard)
}

private func requirePostCanonicalCheckpointWindow(tx: SqliteTransaction, expected: ThreadRecord,
    run: RunId, epoch: Int64, checkpoint: ContextCheckpoint, result: ToolResult, tool: String, expectedPlan: NormalizedOperationPlan,
    owner: LogicalJsonOwnerReservation, retained: Int64, allocate: (Int64) -> LogicalJsonOwnerReservation,
    guard: () -> Result<Unit>, direct: ?DirectToolCallRef): Unit {
    let readback = PostCanonicalCheckpointReadback(tx, owner, retained)
    let complete = PostCanonicalCheckpointBoundary(tx, expected, run, epoch,
        checkpoint.coversThroughItemOrdinal, result, tool, expectedPlan, owner, retained, allocate, guard, direct)
    try {
        match (readback.visit(expected.id, expected.revision, 0, guard,
            { item: ThreadItem, _: OwnedCanonicalThreadItemCustody => complete.read(item) })) {
            case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
        complete.finish()
        requirePostCanonicalCheckpointReceipt(tx, expected, run, epoch, complete.operation.getOrThrow(),
            complete.callItem.getOrThrow(), complete.resultItem.getOrThrow(), result.receiptId, result.output,
            owner, retained, allocate, guard)
        let digest = match (ownedContextSourceDigest(expected, readback,
            checkpoint.coversThroughItemOrdinal, guard)) {
            case Result.Ok(value) => value; case Result.Err(error) => throw IllegalStateException(error.code) }
        if (digest != checkpoint.sourceDigest) {
            throw IllegalStateException("post-canonical checkpoint source changed during projection write") }
        journalStreamCheck(guard)
    } finally { complete.close() }
}

// Original durable plan wrapper, measured before construction under the SAME
// owner. The canonical argument DOM remains in its original retained plan;
// comparison never encodes a second complete argument String. SQL raw/DOM
// payment adds this still-live wrapper peak before decoding either copy.
private func withPostCanonicalCheckpointExpectedPlan(plan: NormalizedOperationPlan,
    owner: LogicalJsonOwnerReservation, retained: Int64, guard: () -> Result<Unit>,
    consume: (AgentValue, Int64) -> Unit): Unit {
    var wrappers: Int64 = 256
    wrappers = journalStreamAdd(wrappers, ownedThreadReadbackMultiply(plan.requiredCapabilities.size, 4))
    wrappers = journalStreamAdd(wrappers, plan.resolvedPaths.size)
    wrappers = journalStreamAdd(wrappers, plan.resolvedHosts.size)
    wrappers = journalStreamAdd(wrappers, plan.relevantEnvironment.size)
    wrappers = journalStreamAdd(wrappers, plan.approvalMetadata.assessment.flags.size)
    wrappers = journalStreamAdd(wrappers, plan.approvalMetadata.assessment.reasons.size)
    wrappers = journalStreamAdd(wrappers, ownedThreadReadbackMultiply(plan.contextReadFacts.size, 64))
    let peak = journalStreamAdd(retained, journalStreamAdd(1048576,
        ownedThreadReadbackMultiply(wrappers, 2048)))
    owner.ensureRetainedPeak(peak)
    journalStreamCheck(guard)
    let original = livePolicyPlanValue(plan)
    let extent = livePolicyStoredExtent(original)
    if (extent.bytes > 8388608) {
        throw IllegalStateException("checkpoint original plan exceeds its actual durable codec") }
    consume(original, peak)
    journalStreamCheck(guard)
}
