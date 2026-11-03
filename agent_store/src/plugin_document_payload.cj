package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Only readPluginDocuments creates this finite transaction proof, after the
// actual private source, complete plan, pending parent and handoff checks.
// Neither a generic observer nor a forged descriptor can manufacture it.
public class SqlitePluginDocumentPayloadReadProof <: PluginDocumentPayloadReadProof {
    private let transaction: SqliteTransaction
    private let source: DirectToolCallRef
    private let encodedPlan: String
    private let actualLane: LaneId
    private let actualKey: String
    private let actualRevision: Int64
    private let actualBytes: Int64
    private let lock = Mutex()
    private var active = true
    private var verified: ?String = None
    public prop threadId: ThreadId { get() { source.threadId } }
    public prop runId: RunId { get() { source.runId } }
    public prop operationId: OperationId { get() { source.operationId } }
    public prop laneId: LaneId { get() { actualLane } }
    public prop key: String { get() { actualKey } }
    public prop revision: Int64 { get() { actualRevision } }
    public prop bytes: Int64 { get() { actualBytes } }

    init(transaction: SqliteTransaction, source: DirectToolCallRef, plan: NormalizedOperationPlan,
        lane: LaneId, key: String, revision: Int64, bytes: Int64) {
        this.transaction = transaction; this.source = source; this.encodedPlan = encodeOperationPlan(plan)
        this.actualLane = lane; this.actualKey = key; this.actualRevision = revision; this.actualBytes = bytes
    }
    public func plan(): NormalizedOperationPlan { decodeOperationPlan(encodedPlan) }

    // The caller must reserve at least the declared raw-byte copy budget before
    // this method. Product's only implementation does so, before SELECT payload.
    // The callback cannot choose an address: it receives the exact row captured
    // by this proof and the same transaction for artifact metadata publication.
    public func materialize(action: (SqliteTransaction, PluginDocumentSnapshot, String) -> Result<AgentValue>): Result<AgentValue> {
        lock.lock()
        try {
            if (!active) { return documentPayloadError("plugin.document_payload_window_closed") }
            active = false
            let actualPlan = decodeOperationPlan(encodedPlan)
            requireContextReadExecutingInTransaction(transaction, source, actualPlan)
            let lane = requirePluginDocumentReadScope(transaction, source, actualPlan)
            if (lane.value != actualLane.value) { return documentPayloadError("plugin.document_payload_scope_changed") }
            let namespace = httpIntentText(actualPlan.canonicalArguments.field("binding").getOrThrow(), "namespace")
            let rows = queryPluginDocumentRows(transaction,"SELECT revision,payload,length(CAST(payload AS BLOB)) FROM plugin_documents " +
                "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                [SqlParameter.Text(source.threadId.value), SqlParameter.Text(actualLane.value),
                    SqlParameter.Text(namespace), SqlParameter.Text(actualKey)])
            if ((actualRevision == 0 && !rows.isEmpty()) || (actualRevision > 0 &&
                (rows.size != 1 || rows[0].required(0) != actualRevision.toString() || rows[0].required(2) != actualBytes.toString()))) {
                return documentPayloadError("plugin.document_payload_source_changed") }
            let raw = if (actualRevision == 0) { "null" } else { rows[0].required(1) }
            if (raw.size != actualBytes) { return documentPayloadError("plugin.document_payload_source_changed") }
            let snapshot = PluginDocumentSnapshot(source.threadId, actualLane, namespace, actualKey, actualRevision, raw)
            match(transaction.documentStorageBackend(namespace,actualKey)){
                case Some(backend)=>backend.recordRead(transaction,source,actualPlan,snapshot);case None=>()}
            let digest = modelPolicySha256Text(raw)
            let value = match (action(transaction, snapshot, digest)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(result) => result }
            let payload = match (parsePluginDocumentPayloadReference(value)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(result) => result }
            if (payload.bytes != actualBytes || payload.digest != digest) {
                return documentPayloadError("plugin.document_payload_content_changed") }
            requirePluginDocumentVersion(transaction, snapshot)
            requireDocumentPayloadMetadata(transaction, payload)
            let evidence = objectValue([ValueField("schema", textValue("axyndra.document-payload-observation/v1")),
                ValueField("thread_id", textValue(source.threadId.value)), ValueField("lane_id", textValue(actualLane.value)),
                ValueField("run_id", textValue(source.runId.value)), ValueField("epoch", integerValue(source.epoch)),
                ValueField("read_operation_id", textValue(source.operationId.value)),
                ValueField("read_item_id", textValue(source.canonicalItemId.value)),
                ValueField("plan_sha256", textValue(modelPolicySha256Text(encodedPlan))),
                ValueField("binding", actualPlan.canonicalArguments.field("binding").getOrThrow()),
                ValueField("key", textValue(actualKey)), ValueField("revision", integerValue(actualRevision)),
                ValueField("payload", payload.value())])
            let encoded = encodeStoredValue(evidence)
            let prior = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind='plugin_document_payload_observed'",
                [SqlParameter.Text(source.operationId.value)])
            var same: Int64 = 0
            for (row in prior) {
                let old = decodeStoredValue(row.required(0))
                if (httpIntentText(old, "key") == actualKey) {
                    if (row.required(0) != encoded) { return documentPayloadError("plugin.document_payload_observation_changed") }
                    same++
                }
            }
            if (same > 1 || prior.size > 8 || (same == 0 && prior.size >= 8)) {
                return documentPayloadError("plugin.document_payload_observation_ambiguous") }
            if (same == 0) {
                transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                    "VALUES(?,?,?,'plugin_document_payload_observed',?,?)", [SqlParameter.Text(source.threadId.value),
                        SqlParameter.Text(source.runId.value), SqlParameter.Text(source.operationId.value),
                        SqlParameter.Text(encoded), SqlParameter.Int64Value(agentUtcMillis())])
            }
            verified = Some(stringifyUnifiedJson(payload.value()))
            Result.Ok(payload.value())
        } catch (error: PluginDocumentGuardFailure) { Result.Err(error.failure) }
        catch (_: Exception) { documentPayloadError("plugin.document_payload_unverified") }
        finally { lock.unlock() }
    }
    func close(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
    func verifiedResult(value: AgentValue): Bool {
        lock.lock(); try { match (verified) {
            case Some(expected) => expected == stringifyUnifiedJson(value)
            case None => false } } finally { lock.unlock() }
    }
}

func requireDocumentPayloadMetadata(transaction: SqliteTransaction, payload: PluginDocumentPayloadReference): Unit {
    let rows = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(payload.digest)])
    if (rows.size != 1 || rows[0].required(0) != "text/plain; charset=utf-8" || rows[0].required(1) != payload.bytes.toString() ||
        rows[0].required(3) != "blobs/" + payload.digest + ".txt") { throw IllegalStateException("document payload metadata changed") }
    let value = parseUnifiedJson(rows[0].required(2), maxBytes: 4096, maxDepth: 4)
    if (!httpIntentExactFields(value, ["version", "ref", "sha256", "bytes", "content_type"]) ||
        value.field("version").getOrThrow().unifiedKind != ValueKind.Number || value.field("version").getOrThrow().asNumberText() != "1" ||
        httpIntentText(value, "ref") != "blob:sha256:" + payload.digest || httpIntentText(value, "sha256") != payload.digest ||
        value.field("bytes").getOrThrow().unifiedKind != ValueKind.Number || value.field("bytes").getOrThrow().asNumberText() != payload.bytes.toString() ||
        httpIntentText(value, "content_type") != "text/plain; charset=utf-8") {
        throw IllegalStateException("document payload MIME or metadata identity changed") }
}

func documentPayloadError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, "document payload no longer matches its actual canonical read"))
}
