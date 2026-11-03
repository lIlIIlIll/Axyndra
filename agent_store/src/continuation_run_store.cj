package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Host composition injects accounting verification from Persistence. Store
// owns the transaction; the callback MUST use only this supplied transaction,
// never reenter Runtime or the live control owner's lock. Missing means deny.
public interface ContinuationRunTransactionVerifier {
    func consume(transaction: SqliteTransaction, proof: ContinuationRunTransactionProof): Result<Unit>
}

// This proof cannot be reconstructed from persisted origin/audit DTOs. It is
// valid only inside its original transaction while Runtime holds the actual
// live owner's startup window. A verifier retaining it cannot reuse it later.
public class ContinuationRunTransactionProof {
    public let origin: ContinuationRunOrigin
    private let transaction: SqliteTransaction
    private let transition: ThreadTransition
    private let admission: ContinuationRunAdmission
    init(transaction: SqliteTransaction, transition: ThreadTransition, admission: ContinuationRunAdmission) {
        this.transaction = transaction; this.transition = transition; this.admission = admission
        origin = admission.origin
    }
    public func requestSnapshot(): AgentValue {
        decodeStoredValue(encodeStoredValue(transition.continuationRequest))
    }
    public func launchSnapshot(): AgentValue {
        decodeStoredValue(encodeStoredValue(objectValue([
            ValueField("lane", transition.runLaneSnapshot), ValueField("context", transition.runContextSnapshot),
            ValueField("budget", transition.runBudgetSnapshot)])))
    }
    public func validate(transaction: SqliteTransaction): Result<Unit> {
        if (!refEq(transaction, this.transaction)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "continuation.transaction_changed", "continuation proof belongs to its original Run transaction")) }
        admission.verifyTransition(transition)
    }
    // Scope polling pays/checks each historical read without rehashing the
    // complete immutable request on every row. The complete transition is
    // still verified at entry, claim publication and after all Run writes.
    public func validateWindow(transaction: SqliteTransaction): Result<Unit> {
        if (!refEq(transaction, this.transaction)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "continuation.transaction_changed", "continuation proof belongs to its original Run transaction")) }
        admission.verifyStartWindow()
    }
}

func verifyContinuationTurnStart(transaction: SqliteTransaction, transition: ThreadTransition,
    verifier: ?ContinuationRunTransactionVerifier): Unit {
    let item = transition.committedItems[0]
    if (item.provenance.continuationOrigin.isNone() && transition.continuationAdmission.isNone()) { return }
    let admission = transition.continuationAdmission.getOrThrow()
    match (admission.verifyTransition(transition)) { case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
    let actual = match (verifier) { case Some(value) => value
        case None => throw IllegalStateException("continuation.transaction_verifier_missing") }
    let proof = ContinuationRunTransactionProof(transaction, transition, admission)
    match (actual.consume(transaction, proof)) { case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
}

// Historical/current fact verification only, never an admission mint. A copied
// SystemNote on another Thread/Run or a bare DTO cannot satisfy this proof.
public func requireConsumedContinuationRun(transaction: SqliteTransaction, threadId: ThreadId,
    turnId: SemanticTurnId, runId: RunId, epoch: Int64): Unit {
    let rows = transaction.query("SELECT i.id,i.payload,i.provenance,r.epoch,r.budget FROM runs r " +
        "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id JOIN items i ON i.id=t.user_item_id " +
        "AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id WHERE r.id=? AND r.thread_id=? AND r.turn_id=? AND i.kind='system_note'",
        [SqlParameter.Text(runId.value), SqlParameter.Text(threadId.value), SqlParameter.Text(turnId.value)])
    if (rows.size != 1) { throw IllegalStateException("continuation durable owner is missing") }
    let provenance = decodeStoredProvenance(rows[0].required(2))
    validateThreadItemProvenance(decodeStoredThreadContent(rows[0].required(1)), provenance)
    let origin = provenance.continuationOrigin.getOrThrow()
    if (origin.threadId != threadId.value || origin.turnId != turnId.value || origin.runId != runId.value ||
        origin.initiatorItemId != rows[0].required(0) || origin.epoch != epoch || rows[0].required(3) != epoch.toString()) {
        throw IllegalStateException("continuation durable owner identity changed") }
    let proof = transaction.query("SELECT payload FROM audit_events WHERE thread_id=? AND run_id=? AND kind='host_continuation_claim_consumed_v1'",
        [SqlParameter.Text(threadId.value), SqlParameter.Text(runId.value)])
    if (proof.size != 1) { throw IllegalStateException("continuation claim is absent or duplicated") }
    let record = decodeStoredValue(proof[0].required(0))
    if (!httpIntentExactFields(record, ["origin", "request", "launch"]) ||
        encodeStoredValue(record.field("origin").getOrThrow()) != encodeStoredValue(continuationRunOriginValue(origin)) ||
        modelPolicySha256Text(canonicalAgentValue(record.field("request").getOrThrow())) != origin.requestDigest) {
        throw IllegalStateException("continuation Run has no exact same-transaction consumed claim") }
    let launch = record.field("launch").getOrThrow()
    if (!httpIntentExactFields(launch, ["lane", "context", "budget"]) ||
        continuationRunLaunchDigest(launch.field("lane").getOrThrow(), launch.field("context").getOrThrow(),
            launch.field("budget").getOrThrow()) != origin.launchDigest ||
        encodeStoredValue(launch.field("budget").getOrThrow()) != rows[0].required(4)) {
        throw IllegalStateException("continuation initial launch or immutable Run budget changed") }
    // Context/catalog safe cuts preserve this initial immutable composition;
    // comparing against the current Run lane/context would reject valid cuts.
    let initial = transaction.query("SELECT digest,payload FROM composition_snapshots WHERE id=?",
        [SqlParameter.Text("composition-" + runId.value)])
    if (initial.size != 1) { throw IllegalStateException("continuation initial composition is missing") }
    let composition = decodeCompositionSnapshot(initial[0].required(1))
    if (!composition.isSealed() || composition.digest != initial[0].required(0) ||
        composition.toolVisibilityDigest != modelPolicySha256Text(encodeStoredValue(launch.field("lane").getOrThrow())) ||
        composition.promptGraphDigest != modelPolicySha256Text(encodeStoredValue(launch.field("context").getOrThrow()))) {
        throw IllegalStateException("continuation initial composition differs from its admitted launch") }
}

func requireUserOrConsumedContinuation(transaction: SqliteTransaction, threadId: ThreadId,
    turnId: SemanticTurnId, runId: RunId, epoch: Int64): Unit {
    let rows = transaction.query("SELECT i.kind FROM runs r JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id " +
        "JOIN items i ON i.id=t.user_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id " +
        "WHERE r.id=? AND r.thread_id=? AND r.turn_id=?", [SqlParameter.Text(runId.value), SqlParameter.Text(threadId.value), SqlParameter.Text(turnId.value)])
    if (rows.size != 1) { throw IllegalStateException("canonical Run initiator is missing") }
    if (rows[0].required(0) == "user_message") { return }
    requireConsumedContinuationRun(transaction, threadId, turnId, runId, epoch)
}

public func consumedContinuationRequest(transaction: SqliteTransaction, item: ThreadItem): AgentValue {
    let origin = item.provenance.continuationOrigin.getOrThrow()
    requireConsumedContinuationRun(transaction, item.threadId, item.turnId, RunId(origin.runId), origin.epoch)
    let current = transaction.query("SELECT payload,provenance FROM items WHERE id=? AND thread_id=? AND turn_id=?",
        [SqlParameter.Text(item.id.value), SqlParameter.Text(item.threadId.value), SqlParameter.Text(item.turnId.value)])
    if (current.size != 1 || current[0].required(0) != encodeStoredThreadContent(item.content) ||
        current[0].required(1) != encodeStoredProvenance(item.provenance)) {
        throw IllegalStateException("continuation model input does not own its exact canonical initiator") }
    let proof = transaction.query("SELECT payload FROM audit_events WHERE thread_id=? AND run_id=? AND kind='host_continuation_claim_consumed_v1'",
        [SqlParameter.Text(item.threadId.value), SqlParameter.Text(origin.runId)])
    decodeStoredValue(proof[0].required(0)).field("request").getOrThrow()
}
