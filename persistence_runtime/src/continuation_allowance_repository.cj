package persistence_runtime

import agent_domain.*
import agent_store.*
import std.convert.*
import yjson.*
import yjson_support.*

// These are persisted accounting/control descriptions. No type in this file
// is a Runtime admission, user authorization, cancellation owner or budget
// ledger. In particular, reopening these facts cannot authorize a new Run.
public class ContinuationAllowanceAddress {
    public let threadId: ThreadId
    public let laneId: LaneId
    public let namespace: String
    public let documentKey: String
    public init(threadId: ThreadId, laneId: LaneId, namespace: String, documentKey: String) {
        if (threadId.value == "" || laneId.value == "" || namespace == "" || documentKey == "" ||
            threadId.value.size > 256 || laneId.value.size > 128 || namespace.size > 128 || documentKey.size > 128) {
            throw IllegalArgumentException("continuation accounting address is empty or too large")
        }
        this.threadId = threadId; this.laneId = laneId
        this.namespace = namespace; this.documentKey = documentKey
    }
}

public enum ContinuationAllowanceControl {
    Create(String, ?Int64) | Replace(String, ?Int64) | Pause | Resume | Close | SetBudget(?Int64) | RestartPause | ResumeOrCreate(String, ?Int64)
}

public class ContinuationAllowanceFacts {
    public let address: ContinuationAllowanceAddress
    public let eventId: Int64
    public let revision: Int64
    public let allowanceId: String
    public let generation: Int64
    public let enabled: Bool
    public let closed: Bool
    public let tokenBudget: ?Int64
    public let tokensUsed: Int64
    public let observedTotalTokens: Int64
    public let controlSourceDigest: String
    let storedTokensUsed: Int64
    let baselineTokens: Int64
    let rawPayload: String
    init(address: ContinuationAllowanceAddress, eventId: Int64, revision: Int64, allowanceId: String,
        generation: Int64, enabled: Bool, closed: Bool, tokenBudget: ?Int64, tokensUsed: Int64,
        observedTotalTokens: Int64, controlSourceDigest: String, storedTokensUsed: Int64,
        baselineTokens: Int64, rawPayload: String) {
        this.address = address; this.eventId = eventId; this.revision = revision; this.allowanceId = allowanceId
        this.generation = generation; this.enabled = enabled; this.closed = closed; this.tokenBudget = tokenBudget
        this.tokensUsed = tokensUsed; this.observedTotalTokens = observedTotalTokens
        this.controlSourceDigest = controlSourceDigest; this.storedTokensUsed = storedTokensUsed
        this.baselineTokens = baselineTokens; this.rawPayload = rawPayload
    }
    // Descriptive only. Actual Run admission MUST also possess the private
    // live host control seal, revalidate and consume the exact claim in its
    // actual new Run transaction. This predicate cannot replace those checks.
    public func payloadDigest(): String { modelPolicySha256Text(rawPayload) }
    public func hasRemainingTokens(): Bool {
        enabled && !closed && match (tokenBudget) { case Some(limit) => tokensUsed < limit; case None => true }
    }
}

public class ContinuationAllowanceRepository {
    private let runs: SqliteRunRepository
    public init(runs: SqliteRunRepository) { this.runs = runs }

    // Call only inside the caller's existing SqliteDatabase transaction.
    // Exact kind+Thread addresses one host stream; no arbitrary audit scan.
    public func readFacts(transaction: SqliteTransaction, address: ContinuationAllowanceAddress): Result<?ContinuationAllowanceFacts> {
        try {
            let rows = transaction.query("SELECT id,payload FROM audit_events WHERE thread_id=? AND kind=? ORDER BY id DESC LIMIT 1",
                [SqlParameter.Text(address.threadId.value), SqlParameter.Text(allowanceAuditKind(address))])
            if (rows.isEmpty()) { return Result.Ok(None) }
            let stats = match (runs.statsInTransaction(transaction, SessionId(address.threadId.value))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let total = allowanceTotal(stats)
            let raw = rows[0].required(1)
            if (raw.size > 16384) { throw IllegalStateException("continuation facts exceed their bound") }
            let value = decodeStoredValue(raw)
            if (!httpIntentExactFields(value, ["schema", "address", "revision", "previous_event_id", "previous_payload_sha256",
                "allowance_id", "generation", "enabled", "closed", "token_budget", "tokens_used", "baseline_tokens", "control_source_digest"]) ||
                httpIntentText(value, "schema") != "axyndra.continuation-accounting/v1" ||
                canonicalAgentValue(value.field("address").getOrThrow()) != canonicalAgentValue(allowanceAddressValue(address))) {
                throw IllegalStateException("continuation facts enclosure changed")
            }
            let revision = allowanceInteger(value, "revision"); let generation = allowanceInteger(value, "generation")
            let used = allowanceInteger(value, "tokens_used"); let baseline = allowanceInteger(value, "baseline_tokens")
            let previousId = allowanceInteger(value, "previous_event_id")
            let id = httpIntentText(value, "allowance_id"); let source = httpIntentText(value, "control_source_digest")
            let enabled = allowanceBoolean(value, "enabled"); let closed = allowanceBoolean(value, "closed")
            let budget = allowanceBudget(value.field("token_budget").getOrThrow())
            if (revision < 1 || generation < 1 || used < 0 || baseline < 0 || previousId < 0 ||
                id == "" || id.size > 256 || !allowanceDigest(source) || (closed && enabled) || total < baseline) {
                throw IllegalStateException("continuation accounting facts are invalid or statistics regressed")
            }
            if (revision == 1) {
                if (previousId != 0 || httpIntentText(value, "previous_payload_sha256") != "") {
                    throw IllegalStateException("initial continuation facts contain a previous event") }
            } else {
                let previous = transaction.query("SELECT payload FROM audit_events WHERE id=? AND thread_id=? AND kind=?",
                    [SqlParameter.Int64Value(previousId), SqlParameter.Text(address.threadId.value), SqlParameter.Text(allowanceAuditKind(address))])
                if (previous.size != 1 || previous[0].required(0).size > 16384 ||
                    modelPolicySha256Text(previous[0].required(0)) != httpIntentText(value, "previous_payload_sha256") ||
                    allowanceInteger(decodeStoredValue(previous[0].required(0)), "revision") != revision - 1 ||
                    allowanceInteger(decodeStoredValue(previous[0].required(0)), "generation") != generation - 1) {
                    throw IllegalStateException("continuation facts predecessor is missing or changed") }
            }
            let observed = if (enabled) { allowanceAdd(used, total - baseline) } else { used }
            Result.Ok(Some(ContinuationAllowanceFacts(address, Int64.parse(rows[0].required(0)), revision, id,
                generation, enabled, closed, budget, observed, total, source, used, baseline, raw)))
        } catch (_: Exception) { allowanceError("continuation.accounting_corrupt", AgentErrorKind.RecoveryRequired) }
    }

    // This is a data transaction primitive, intentionally not a public Product
    // service and not a grant mint. The forthcoming host control consumer must
    // validate actual user provenance in this SAME transaction before calling
    // it. Plugin document CAS by itself never calls this method.
    public func appendControlFacts(transaction: SqliteTransaction, address: ContinuationAllowanceAddress,
        expected: ?ContinuationAllowanceFacts, control: ContinuationAllowanceControl,
        controlSourceDigest: String, observedAtMillis: Int64): Result<ContinuationAllowanceFacts> {
        if (!allowanceDigest(controlSourceDigest) || observedAtMillis < 0) {
            return allowanceError("continuation.control_description_invalid", AgentErrorKind.InvalidInput) }
        let actual = match (readFacts(transaction, address)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!allowanceExpected(actual, expected)) {
            return allowanceError("continuation.accounting_conflict", AgentErrorKind.Conflict) }
        if (transaction.query("SELECT id FROM threads WHERE id=?", [SqlParameter.Text(address.threadId.value)]).size != 1) {
            return allowanceError("continuation.thread_missing", AgentErrorKind.Conflict) }
        let total = match (actual) { case Some(value) => value.observedTotalTokens
            case None => match (runs.statsInTransaction(transaction, SessionId(address.threadId.value))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => try { allowanceTotal(value) }
                    catch (_: Exception) { return allowanceError("continuation.accounting_corrupt", AgentErrorKind.RecoveryRequired) } } }
        var id = match (actual) { case Some(value) => value.allowanceId; case None => "" }
        var used = match (actual) { case Some(value) => value.tokensUsed; case None => 0 }
        var enabled = match (actual) { case Some(value) => value.enabled; case None => false }
        var closed = match (actual) { case Some(value) => value.closed; case None => false }
        var budget: ?Int64 = match (actual) { case Some(value) => value.tokenBudget; case None => None }
        // Only the explicit typed user proposal selects this operation.
        // The actual/expected comparison above has already verified absence
        // or the exact current facts in this same document-commit transaction.
        // Existing facts always use the original Resume transition, including
        // its closed refusal and retained identity, usage and token budget.
        let selected = match (control) {
            case ContinuationAllowanceControl.ResumeOrCreate(nextId, nextBudget) =>
                if (actual.isNone()) { ContinuationAllowanceControl.Create(nextId, nextBudget) }
                else { ContinuationAllowanceControl.Resume }
            case _ => control
        }
        match (selected) {
            case ContinuationAllowanceControl.Create(nextId, nextBudget) =>
                if (actual.isSome() && !closed) { return allowanceError("continuation.already_exists", AgentErrorKind.Conflict) }
                id = nextId; budget = nextBudget; used = 0; enabled = true; closed = false
            case ContinuationAllowanceControl.Replace(nextId, nextBudget) =>
                if (actual.isNone() || !enabled || closed || id == nextId) { return allowanceError("continuation.replace_inactive", AgentErrorKind.Conflict) }
                id = nextId; budget = nextBudget; used = 0; enabled = true; closed = false
            case ContinuationAllowanceControl.Pause | ContinuationAllowanceControl.RestartPause =>
                if (actual.isNone()) { return allowanceError("continuation.not_found", AgentErrorKind.Conflict) }
                enabled = false
            case ContinuationAllowanceControl.Resume =>
                if (actual.isNone() || closed) { return allowanceError("continuation.resume_closed", AgentErrorKind.Conflict) }
                enabled = true
            case ContinuationAllowanceControl.Close =>
                if (actual.isNone()) { return allowanceError("continuation.not_found", AgentErrorKind.Conflict) }
                enabled = false; closed = true
            case ContinuationAllowanceControl.SetBudget(nextBudget) =>
                if (actual.isNone() || !enabled || closed) { return allowanceError("continuation.budget_inactive", AgentErrorKind.Conflict) }
                budget = nextBudget
            case ContinuationAllowanceControl.ResumeOrCreate(_, _) =>
                return allowanceError("continuation.control_description_invalid", AgentErrorKind.InvalidInput)
        }
        if (id == "" || id.size > 256 || match (budget) { case Some(value) => value < 1; case None => false }) {
            return allowanceError("continuation.control_description_invalid", AgentErrorKind.InvalidInput) }
        let revision = match (actual) { case Some(value) => value.revision; case None => 0 }
        let generation = match (actual) { case Some(value) => value.generation; case None => 0 }
        if (revision == Int64.Max || generation == Int64.Max) { return allowanceError("continuation.sequence_exhausted", AgentErrorKind.Conflict) }
        let payload = encodeStoredValue(objectValue([
            ValueField("schema", textValue("axyndra.continuation-accounting/v1")), ValueField("address", allowanceAddressValue(address)),
            ValueField("revision", integerValue(revision + 1)), ValueField("previous_event_id", integerValue(match (actual) { case Some(value) => value.eventId; case None => 0 })),
            ValueField("previous_payload_sha256", textValue(match (actual) { case Some(value) => modelPolicySha256Text(value.rawPayload); case None => "" })),
            ValueField("allowance_id", textValue(id)), ValueField("generation", integerValue(generation + 1)),
            ValueField("enabled", boolValue(enabled)), ValueField("closed", boolValue(closed)),
            ValueField("token_budget", match (budget) { case Some(value) => integerValue(value); case None => nullValue() }),
            ValueField("tokens_used", integerValue(used)), ValueField("baseline_tokens", integerValue(total)),
            ValueField("control_source_digest", textValue(controlSourceDigest))]))
        transaction.execute("INSERT INTO audit_events(thread_id,kind,payload,created_at_millis,commit_sequence) VALUES (?,?,?,?,0)",
            [SqlParameter.Text(address.threadId.value), SqlParameter.Text(allowanceAuditKind(address)),
                SqlParameter.Text(payload), SqlParameter.Int64Value(observedAtMillis)])
        let row = transaction.query("SELECT id FROM audit_events WHERE thread_id=? AND kind=? ORDER BY id DESC LIMIT 1",
            [SqlParameter.Text(address.threadId.value), SqlParameter.Text(allowanceAuditKind(address))])
        Result.Ok(ContinuationAllowanceFacts(address, Int64.parse(row[0].required(0)), revision + 1, id, generation + 1,
            enabled, closed, budget, used, total, controlSourceDigest, used, total, payload))
    }
}

func allowanceAddressValue(value: ContinuationAllowanceAddress): AgentValue {
    objectValue([ValueField("thread_id", textValue(value.threadId.value)), ValueField("lane_id", textValue(value.laneId.value)),
        ValueField("namespace", textValue(value.namespace)), ValueField("document_key", textValue(value.documentKey))])
}
func allowanceAuditKind(value: ContinuationAllowanceAddress): String {
    "host_continuation_accounting_v1:" + modelPolicySha256Text(encodeStoredValue(allowanceAddressValue(value)))
}
func allowanceExpected(actual: ?ContinuationAllowanceFacts, expected: ?ContinuationAllowanceFacts): Bool {
    match ((actual, expected)) { case (None, None) => true
        case (Some(left), Some(right)) => left.eventId == right.eventId && left.rawPayload == right.rawPayload &&
            canonicalAgentValue(allowanceAddressValue(left.address)) == canonicalAgentValue(allowanceAddressValue(right.address))
        case _ => false }
}
func allowanceInteger(value: AgentValue, key: String): Int64 {
    let entry = value.field(key).getOrThrow()
    if (entry.unifiedKind != ValueKind.Number) { throw IllegalStateException("continuation integer is malformed") }
    Int64.parse(entry.asNumberText())
}
func allowanceBoolean(value: AgentValue, key: String): Bool {
    let entry = value.field(key).getOrThrow()
    if (entry.unifiedKind != ValueKind.Boolean) { throw IllegalStateException("continuation Boolean is malformed") }
    entry.asBool()
}
func allowanceBudget(value: AgentValue): ?Int64 {
    if (value.unifiedKind == ValueKind.Null) { return None }
    if (value.unifiedKind != ValueKind.Number) { throw IllegalStateException("continuation budget is malformed") }
    let number = Int64.parse(value.asNumberText())
    if (number < 1) { throw IllegalStateException("continuation budget must be positive") }
    Some(number)
}
func allowanceAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) { throw IllegalStateException("continuation accounting overflow") }
    left + right
}
func allowanceTotal(value: SessionRunStats): Int64 { allowanceAdd(value.inputTokens, value.outputTokens) }
func allowanceDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) { if (!((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) { return false } }
    true
}
func allowanceError<T>(code: String, kind: AgentErrorKind): Result<T> {
    Result.Err(AgentError(kind, code, "continuation accounting descriptions do not authorize execution"))
}
