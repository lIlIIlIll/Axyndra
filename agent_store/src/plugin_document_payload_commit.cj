package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Created only by the original derived settlement transaction. The Product
// caller holds the artifact lock before entering the DB, so the content reader
// below never acquires an artifact/registry lock from this transaction.
public class SqlitePluginDocumentPayloadCommitProof <: PluginDocumentPayloadCommitProof {
    private let transaction: SqliteTransaction
    private let actualRun: RunId
    private let actualParent: OperationId
    private let actualOperation: OperationId
    private let intent: PluginDocumentIntent
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var active = true
    private var applied = false
    public prop runId: RunId { get() { actualRun } }
    public prop parentOperationId: OperationId { get() { actualParent } }
    public prop operationId: OperationId { get() { actualOperation } }
    public func payload(): AgentValue { intent.nextPayload.getOrThrow().value() }

    init(transaction: SqliteTransaction, run: RunId, parent: OperationId, operation: OperationId,
        intent: PluginDocumentIntent, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.transaction = transaction; this.actualRun = run; this.actualParent = parent
        this.actualOperation = operation; this.intent = intent; this.allocate = allocate
    }
    // Allocation happens before the callback may read/copy an artifact. The
    // returned raw String is consumed in this scope only; it never becomes a
    // Receipt payload, prepared plan or durable second document repository.
    public func materialize(read: (PluginDocumentPayloadReference) -> Result<String>): Result<Unit> {
        lock.lock()
        try {
            if (!active) { return documentPayloadError("plugin.document_payload_commit_window_closed") }
            active = false
            let next = intent.nextPayload.getOrThrow()
            requireDocumentPayloadMetadata(transaction, next)
            let reservation = allocate(max(1, next.bytes))
            try {
                let raw = match (read(next)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (raw.size != next.bytes || modelPolicySha256Text(raw) != next.digest) {
                    return documentPayloadError("plugin.document_payload_replacement_changed") }
                // Keep the prior v1 canonical JSON and lexical node contract.
                // Reserve decoded cost before constructing the replacement DOM.
                reservation.ensureDecoded(raw.size, logicalJsonNodeCount(raw))
                let decoded = match (decodeAgentValue(raw, maxBytes: PLUGIN_DOCUMENT_MAX_BYTES)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (encodeAgentValue(decoded) != raw) { return documentPayloadError("plugin.document_next_noncanonical") }
                requireDocumentPayloadMetadata(transaction, next)
                replaceDocumentPayloadInTransaction(transaction, intent, raw)
                applied = true
                Result.Ok(())
            } finally { reservation.close() }
        } catch (error: PluginDocumentGuardFailure) { Result.Err(error.failure) }
        catch (_: Exception) { documentPayloadError("plugin.document_payload_commit_failed") }
        finally { lock.unlock() }
    }
    func didApply(): Bool { lock.lock(); try { applied } finally { lock.unlock() } }
    func close(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
}

// The full old revision/byte hash was checked immediately before invoking the
// private committer. The supplied IMMEDIATE transaction prevents interleaved
// writers. No old raw String is retained while allocating the replacement.
func replaceDocumentPayloadInTransaction(transaction: SqliteTransaction, intent: PluginDocumentIntent, raw: String): Unit {
    let binding = intent.binding()
    match(transaction.documentStorageBackend(httpIntentText(binding,"namespace"),intent.key)){
        case Some(backend)=>
            transaction.withBackendAllocationPhase({=>
                let current=backend.read(transaction,ThreadId(httpIntentText(binding,"thread_id")),LaneId(httpIntentText(binding,"lane_id")),
                    httpIntentText(binding,"namespace"),intent.key)
                let expected=intent.expectedPayload.getOrThrow()
                if(current.revision!=intent.expectedRevision || current.encoded.size!=expected.bytes || modelPolicySha256Text(current.encoded)!=expected.digest){
                    throw IllegalStateException("journal payload differs from its exact current read")}
                let _=backend.compareExchange(transaction,current,raw)
            });return
        case None=>()}
    let identity = [SqlParameter.Text(httpIntentText(binding, "thread_id")), SqlParameter.Text(httpIntentText(binding, "lane_id")),
        SqlParameter.Text(httpIntentText(binding, "namespace")), SqlParameter.Text(intent.key)]
    let before = transaction.query("SELECT revision,length(CAST(payload AS BLOB)) FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?", identity)
    if ((intent.expectedRevision == 0 && !before.isEmpty()) || (intent.expectedRevision > 0 &&
        (before.size != 1 || before[0].required(0) != intent.expectedRevision.toString() ||
            before[0].required(1) != intent.expectedPayload.getOrThrow().bytes.toString()))) {
        throw IllegalStateException("document changed within its payload transaction") }
    let revision = intent.expectedRevision + 1
    if (intent.expectedRevision == 0) {
        transaction.execute("INSERT INTO plugin_documents(thread_id,lane_id,namespace,document_key,revision,payload) VALUES(?,?,?,?,?,?)",
            [identity[0],identity[1],identity[2],identity[3],SqlParameter.Int64Value(revision),SqlParameter.Text(raw)])
    } else {
        transaction.execute("UPDATE plugin_documents SET revision=?,payload=? WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=? AND revision=?",
            [SqlParameter.Int64Value(revision),SqlParameter.Text(raw),identity[0],identity[1],identity[2],identity[3],SqlParameter.Int64Value(intent.expectedRevision)])
        requireStoreChanged(transaction, "document payload CAS lost its exact revision")
    }
    let after = transaction.query("SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?", identity)
    if (after.size != 1 || after[0].required(0) != revision.toString() || after[0].required(1) != raw) {
        throw IllegalStateException("document payload changed during its CAS") }
}

// The Receipt INSERT or a trusted participant can fail/change data after the
// CAS. Recheck the exact resulting bytes at the end of the same transaction;
// this does not open a second transaction, invoke a reader or replay a write.
func requireCompletedDocumentPayload(transaction: SqliteTransaction, plan: NormalizedOperationPlan,
    allocate: ?(Int64) -> LogicalJsonOwnerReservation): Unit {
    if (plan.toolName != HOST_PLUGIN_DOCUMENT_TOOL) { return }
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA){
        requireCompletedRowJournalPayload(transaction,plan,allocate);return}
    let intent = parsePluginDocumentIntent(plan.canonicalArguments).value().getOrThrow()
    if (!intent.referencesPayload) { return }
    let expected = intent.nextPayload ?? intent.expectedPayload.getOrThrow()
    let check = parsePluginDocumentIntent(objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),
        ValueField("binding",intent.binding()),ValueField("intent",objectValue([
            ValueField("id",textValue(intent.id)),ValueField("key",textValue(intent.key)),ValueField("mode",textValue("read")),
            ValueField("expected_revision",integerValue(intent.expectedRevision + (if (intent.compareExchange) { 1 } else { 0 }))),
            ValueField("expected_payload",expected.value()),ValueField("next_payload",nullValue())]))])).value().getOrThrow()
    requireDocumentPayloadCurrent(transaction, check, allocate)
    requireDocumentPayloadMetadata(transaction, expected)
}
