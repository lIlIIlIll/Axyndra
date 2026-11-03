package agent_store

import agent_domain.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Descriptive durable facts, not a network/credential grant or a Runtime seal.
public class ModelProviderDispatchFacts {
    public let attemptId: ModelAttemptId
    public let runId: RunId
    public let threadId: ThreadId
    public let workspaceId: String
    public let epoch: Int64
    public let requestId: String
    public let semanticDigest: String
    public let wirePolicyDigest: String
    public let transcriptSnapshot: String
    public init(attemptId: ModelAttemptId, runId: RunId, threadId: ThreadId, workspaceId: String,
        epoch: Int64, requestId: String, semanticDigest: String, wirePolicyDigest: String, transcriptSnapshot: String) {
        this.attemptId = attemptId; this.runId = runId; this.threadId = threadId
        this.workspaceId = workspaceId; this.epoch = epoch; this.requestId = requestId
        this.semanticDigest = semanticDigest; this.wirePolicyDigest = wirePolicyDigest
        this.transcriptSnapshot = transcriptSnapshot
    }
}

// A per-dispatch read observation, never an execution or credential grant.
// Construction stays in this Store package; callers cannot inject cache facts.
public class ModelProviderDispatchObservation {
    public let facts: ModelProviderDispatchFacts
    private let readCurrent: () -> Result<ModelProviderDispatchFacts>
    init(facts: ModelProviderDispatchFacts, readCurrent: () -> Result<ModelProviderDispatchFacts>) {
        this.facts = facts; this.readCurrent = readCurrent
    }
    public func read(): Result<ModelProviderDispatchFacts> { readCurrent() }
}

// One last successfully verified immutable byte string. No global cache, hash-
// only trust, table, dispatch claim or grant is introduced. Changes are decoded
// and sealed again before replacing this witness.
class ModelProviderContinuationWitness {
    let lock = Mutex()
    var payload: ?String = None
    var digest = ""
    var runId = ""
    var attemptId = ""
}

// Reads the existing Core Attempt/continuation atomically. No tables, Attempt,
// dispatch claim, Decision, receipt or retry policy are created here.
public class SqliteModelProviderDispatchReader {
    private let database: SqliteDatabase
    public init(database: SqliteDatabase) { this.database = database }

    public func read(request: ModelRequest, snapshot: String,
        initial!: Bool = false): Result<ModelProviderDispatchFacts> {
        match (observe(request, snapshot, initial: initial)) {
            case Result.Ok(value) => Result.Ok(value.facts)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func observe(request: ModelRequest, snapshot: String,
        initial!: Bool = false): Result<ModelProviderDispatchObservation> {
        try {
            let canonical = canonicalAgentValue(modelRequestSnapshotValue(request))
            let semantic = modelPolicySha256Text(canonical)
            let wire = modelRequestWirePolicyDigest(request)
            let witness = ModelProviderContinuationWitness()
            let facts = match (readObserved(request, snapshot, canonical, semantic, wire, witness, initial)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(ModelProviderDispatchObservation(facts, { =>
                match (readObserved(request, snapshot, canonical, semantic, wire, witness, false)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(current) =>
                        if (current.attemptId.value != facts.attemptId.value || current.runId.value != facts.runId.value ||
                            current.threadId.value != facts.threadId.value || current.workspaceId != facts.workspaceId ||
                            current.epoch != facts.epoch) { modelProviderObservationDenied<ModelProviderDispatchFacts>() }
                        else { Result.Ok(current) }
                }
            }))
        } catch (_: Exception) { modelProviderObservationDenied<ModelProviderDispatchObservation>() }
    }

    private func readObserved(request: ModelRequest, snapshot: String, canonical: String,
        semantic: String, wire: String, witness: ModelProviderContinuationWitness,
        initial: Bool): Result<ModelProviderDispatchFacts> {
        witness.lock.lock()
        try {
            // ModelRequest contains arrays. Compare their current canonical
            // bytes on every poll instead of trusting object identity or a let.
            if (!canonicalAgentValueMatches(modelRequestSnapshotValue(request), canonical) ||
                modelRequestWirePolicyDigest(request) != wire) {
                throw IllegalStateException("provider input changed after observation")
            }
            database.transaction<Result<ModelProviderDispatchFacts>>({ transaction =>
                let rows = transaction.query(
                    "SELECT a.id,a.run_id,r.thread_id,t.workspace_id,r.epoch,a.semantic_request_digest," +
                    "a.wire_policy_digest,CAST(a.transcript_snapshot AS BLOB)=CAST(? AS BLOB)," +
                    "COALESCE(CAST(c.payload AS BLOB)=CAST(? AS BLOB),0),c.digest,c.active_attempt_id,a.replay_barrier,a.policy_reason,r.state " +
                    "FROM model_attempts a JOIN runs r ON r.id=a.run_id JOIN threads t ON t.id=r.thread_id " +
                    "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
                    "JOIN run_continuations c ON c.run_id=r.id WHERE a.provider_request_id=? " +
                    "AND r.state IN ('running','waiting_approval') AND t.active_turn_id=r.turn_id AND turn.active_run_id=r.id " +
                    "AND a.lifecycle='streaming' AND a.dispatch_state='dispatch_claimed' " +
                    "AND a.dispatch_started_at_millis IS NOT NULL AND a.completed_at_millis IS NULL " +
                    "AND a.replay_barrier NOT IN ('cancelled','run_deadline') " +
                    "AND NOT EXISTS(SELECT 1 FROM model_decisions d WHERE d.attempt_id=a.id)",
                    [SqlParameter.Text(snapshot),
                        match (witness.payload) {
                            case Some(value) => SqlParameter.Text(value)
                            case None => SqlParameter.Null
                        }, SqlParameter.Text(request.requestId)])
                if (rows.size != 1) { throw IllegalStateException("provider Attempt is not current") }
                let row = rows[0]
                if (row.required(5) != semantic || row.required(6) != wire || row.required(7) != "1" ||
                    (initial && row.required(11) != "none")) {
                    throw IllegalStateException("provider request differs from its claimed Attempt")
                }
                if (row.required(12) == "internal_approval_review" || row.required(12) == "internal_context_compaction") {
                    let internalWitness = verifyInternalModelAttemptCurrent(transaction, ModelAttemptId(row.required(0)), RunId(row.required(1)))
                    let input = internalWitness.field("input").getOrThrow()
                    if (!canonicalAgentValueMatches(input.field("request").getOrThrow(), canonical) ||
                        httpIntentText(input, "request_id") != request.requestId) {
                        throw IllegalStateException("internal provider neutral input differs")
                    }
                    return Result.Ok(ModelProviderDispatchFacts(ModelAttemptId(row.required(0)), RunId(row.required(1)),
                        ThreadId(row.required(2)), row.required(3), Int64.parse(row.required(4)), request.requestId,
                        semantic, row.required(6), snapshot))
                }
                if (row.required(13) != "running" || row.required(10) != row.required(0)) {
                    throw IllegalStateException("ordinary provider Attempt has no current model effect")
                }
                if (row.required(8) != "1" || witness.digest != row.required(9) ||
                    witness.runId != row.required(1) || witness.attemptId != row.required(0)) {
                    // Same-transaction exact byte comparison above controls
                    // copying; any changed proof is decoded and sealed again.
                    let payloadRows = transaction.query(
                        "SELECT payload FROM run_continuations WHERE run_id=?",
                        [SqlParameter.Text(row.required(1))])
                    if (payloadRows.size != 1) {
                        throw IllegalStateException("provider continuation disappeared")
                    }
                    let payload = payloadRows[0].required(0)
                    let current = decodeDurableRunContinuation(payload)
                    if (current.digest != row.required(9) || current.runId.value != row.required(1) ||
                        current.attemptId.isNone() || current.attemptId.getOrThrow().value != row.required(0)) {
                        throw IllegalStateException("provider Attempt continuation changed")
                    }
                    match (current.phase) {
                        case RunExecutionPhase.ModelEffectPending(_) | RunExecutionPhase.ModelSettling(_) => ()
                        case _ => throw IllegalStateException("provider Attempt has no current model effect")
                    }
                    let projection = optionalRunRequestSnapshotFromDurableContinuation(current).getOrThrow()
                    let checkpoint = projection.field("running_model").getOrThrow()
                    if (checkpoint.unifiedKind != ValueKind.Object ||
                        checkpoint.field("active_attempt_id").getOrThrow().text != row.required(0) ||
                        checkpoint.field("stable_request_id").getOrThrow().text != request.requestId ||
                        checkpoint.field("semantic_request_digest").getOrThrow().text != semantic ||
                        checkpoint.field("wire_policy_digest").getOrThrow().text != row.required(6) ||
                        !canonicalAgentValueMatches(checkpoint.field("canonical_request").getOrThrow(), canonical)) {
                        throw IllegalStateException("provider durable neutral input proof changed")
                    }
                    witness.payload = Some(payload); witness.digest = row.required(9)
                    witness.runId = row.required(1); witness.attemptId = row.required(0)
                }
                Result.Ok(ModelProviderDispatchFacts(ModelAttemptId(row.required(0)), RunId(row.required(1)),
                    ThreadId(row.required(2)), row.required(3), Int64.parse(row.required(4)), request.requestId,
                    semantic, row.required(6), snapshot))
            })
        } catch (_: Exception) { modelProviderObservationDenied<ModelProviderDispatchFacts>() }
        finally { witness.lock.unlock() }
    }
}

func modelProviderObservationDenied<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.provider_attempt_not_current",
        "provider invocation requires the exact current claimed model Attempt"))
}
