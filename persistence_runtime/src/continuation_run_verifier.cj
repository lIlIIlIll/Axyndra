package persistence_runtime

import agent_domain.*
import agent_store.*
import std.convert.*
import yjson.*
import yjson_support.*

// Only a SqliteThreadCommitSink that has already checked a real transient
// Runtime admission invokes this verifier. Public facts/read APIs cannot mint it.
public class SqliteContinuationRunVerifier <: ContinuationRunTransactionVerifier {
    private let facts: ContinuationAllowanceRepository
    private let requireDocumentPin: Bool
    private let documentAllocation: ?(Int64) -> LogicalJsonOwnerReservation
    public init(facts: ContinuationAllowanceRepository, requireDocumentPin!: Bool = false, documentAllocation!: ?(Int64) -> LogicalJsonOwnerReservation = None) {
        this.facts = facts; this.requireDocumentPin = requireDocumentPin; this.documentAllocation = documentAllocation
    }
    public func consume(transaction: SqliteTransaction, proof: ContinuationRunTransactionProof): Result<Unit> {
        match (proof.validate(transaction)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let origin = proof.origin
        let reading: ?ContinuationDocumentReadScope = if (requireDocumentPin) {
            let allocator = match (documentAllocation) { case Some(value) => value; case None =>
                return allowanceError("continuation.observation_capacity_required", AgentErrorKind.PermissionDenied) }
            try { Some(ContinuationDocumentReadScope(allocator,current:{=>
                match(proof.validateWindow(transaction)){case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(_)=>()}
            })) } catch (_: Exception) {
                return allowanceError("continuation.observation_capacity", AgentErrorKind.PermissionDenied) }
        } else { None }
        try {
        let address = ContinuationAllowanceAddress(ThreadId(origin.threadId), LaneId(origin.laneId), origin.namespace, origin.documentKey)
        let actual = match (facts.readFacts(transaction, address)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return allowanceError("continuation.control_missing", AgentErrorKind.PermissionDenied) }
        if (!actual.hasRemainingTokens() || actual.eventId != origin.controlEventId || actual.generation != origin.generation ||
            actual.allowanceId != origin.allowanceId || actual.controlSourceDigest != origin.controlSourceDigest ||
            modelPolicySha256Text(actual.rawPayload) != origin.controlPayloadDigest) {
            return allowanceError("continuation.control_changed_or_exhausted", AgentErrorKind.PermissionDenied) }
        if (!requireDocumentPin && origin.documentObservation.isSome()) {
            return allowanceError("continuation.document_verifier_required", AgentErrorKind.PermissionDenied) }
        if (requireDocumentPin) {
            let currentVersion = match (readContinuationDocumentVersion(transaction, address.threadId, address.laneId,
                address.namespace, address.documentKey, reading.getOrThrow())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let observed: ?AgentValue = match (origin.documentObservation) { case Some(value) => Some(value.value()); case None => None }
            let revision = match (observed) { case Some(value) => Int64.parse(value.field("original_revision").getOrThrow().asNumberText())
                case None => currentVersion.revision }
            let digest = match (observed) { case Some(value) => httpIntentText(value, "original_document_sha256")
                case None => currentVersion.payload.digest }
            // The original actual user control remains mandatory. A later
            // mutation Receipt cannot stand in for the user source/allowance.
            let expectedPin = encodeStoredValue(objectValue([
                ValueField("control_event_id", integerValue(origin.controlEventId)), ValueField("source_digest", textValue(origin.controlSourceDigest)),
                ValueField("lane_id", textValue(origin.laneId)), ValueField("namespace", textValue(origin.namespace)),
                ValueField("document_key", textValue(origin.documentKey)), ValueField("revision", integerValue(revision)),
                ValueField("sha256", textValue(digest))]))
            let pins = reading.getOrThrow().query(transaction,"SELECT a.id,a.operation_id,a.run_id,receipt.id FROM audit_events a " +
                "JOIN operation_receipts receipt ON receipt.operation_id=a.operation_id AND receipt.outcome='completed' " +
                "WHERE a.thread_id=? AND a.kind='host_continuation_control_document_v1' AND a.payload=? LIMIT 2",
                [SqlParameter.Text(origin.threadId), SqlParameter.Text(expectedPin)],4)
            if (pins.size != 1) { return allowanceError("continuation.document_pin_changed", AgentErrorKind.PermissionDenied) }
            match (origin.documentObservation) {
                case Some(observation) =>
                    let value = observation.value()
                    if (pins[0].required(1) != httpIntentText(value, "original_operation_id") ||
                        pins[0].required(2) != httpIntentText(value, "original_run_id") ||
                        pins[0].required(3) != httpIntentText(value, "original_receipt_id") ||
                        actual.observedTotalTokens.toString() != value.field("total_tokens").getOrThrow().asNumberText()) {
                        return allowanceError("continuation.document_pin_changed", AgentErrorKind.PermissionDenied) }
                    match (verifyContinuationDocumentObservation(transaction, address.threadId, address.laneId, address.namespace,
                        address.documentKey, origin.controlSourceDigest, observation, scope: reading.getOrThrow())) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                case None => ()
            }
        }
        let thread = transaction.query("SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id=? AND status='open'",
            [SqlParameter.Text(origin.threadId)])
        let previous = transaction.query("SELECT r.id,r.state,r.epoch,t.state,COALESCE(t.active_run_id,'') FROM runs r " +
            "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id WHERE r.thread_id=? ORDER BY t.ordinal DESC LIMIT 1",
            [SqlParameter.Text(origin.threadId)])
        if (thread.size != 1 || thread[0].required(0) != origin.expectedThreadRevision.toString() || thread[0].required(1) != "" ||
            previous.size != 1 || previous[0].required(0) != origin.previousRunId || previous[0].required(1) != "completed" ||
            previous[0].required(3) != "completed" || previous[0].required(4) != "" ||
            Int64.parse(previous[0].required(2)) != origin.epoch - 1) {
            return allowanceError("continuation.previous_run_not_completed", AgentErrorKind.Conflict) }
        if (!transaction.query("SELECT id FROM runs WHERE id=?", [SqlParameter.Text(origin.runId)]).isEmpty() ||
            !transaction.query("SELECT id FROM audit_events WHERE run_id=? AND kind='host_continuation_claim_consumed_v1'",
                [SqlParameter.Text(origin.runId)]).isEmpty()) { return allowanceError("continuation.claim_replayed", AgentErrorKind.Conflict) }
        // This write is inside the exact transaction that creates the next Run,
        // Turn/SystemNote, composition snapshot and Thread revision. A subsequent
        // SQL failure rolls this claim back as well. It is not a second ledger.
        match(proof.validate(transaction)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,kind,payload,created_at_millis,commit_sequence) VALUES (?,?,?,?,0,0)",
            [SqlParameter.Text(origin.threadId), SqlParameter.Text(origin.runId), SqlParameter.Text("host_continuation_claim_consumed_v1"),
                SqlParameter.Text(encodeStoredValue(objectValue([ValueField("origin", continuationRunOriginValue(origin)),
                    ValueField("request", proof.requestSnapshot()), ValueField("launch", proof.launchSnapshot())])))])
        proof.validate(transaction)
        } finally { match (reading) { case Some(value) => value.close(); case None => () } }
    }
}
