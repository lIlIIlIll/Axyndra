package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Store-internal data primitives. They neither open a second transaction nor
// accept worker callbacks. The existing derived settlement proves canonical
// source/plan/handoff, calls these helpers, and inserts its unique Receipt in
// that same transaction. The native broker is a separate required integration.
func requirePluginDocumentVersion(transaction: SqliteTransaction,
    expected: PluginDocumentSnapshot): Unit {
    if (!documentIdentity(expected.threadId, expected.laneId, expected.namespace, expected.key) ||
        expected.revision < 0 || expected.encoded.size > PLUGIN_DOCUMENT_MAX_BYTES ||
        (expected.revision == 0 && expected.encoded != "null")) {
        throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.InvalidInput,
            "plugin.document_expected_invalid", "invalid expected document identity or bytes")) }
    let rows = queryPluginDocumentRows(transaction,"SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
        [SqlParameter.Text(expected.threadId.value), SqlParameter.Text(expected.laneId.value),
            SqlParameter.Text(expected.namespace), SqlParameter.Text(expected.key)])
    if ((expected.revision == 0 && !rows.isEmpty()) ||
        (expected.revision > 0 && (rows.size != 1 || Int64.parse(rows[0].required(0)) != expected.revision ||
            rows[0].required(1) != expected.encoded))) {
        throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.Conflict,
            "plugin.document_conflict", "document changed since its frozen preparation")) }
}

func compareExchangePluginDocumentInTransaction(transaction: SqliteTransaction,
    expected: PluginDocumentSnapshot, encodedNext: String): PluginDocumentSnapshot {
    if (expected.revision == 9223372036854775807 || encodedNext.size > PLUGIN_DOCUMENT_MAX_BYTES) {
        throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.InvalidInput,
            "plugin.document_next_invalid", "document revision or replacement exceeds its bound")) }
    match(transaction.documentStorageBackend(expected.namespace,expected.key)){
        case Some(backend)=>return backend.compareExchange(transaction,expected,encodedNext);case None=>()}
    // Recheck even when the caller already inspected the row; this helper is
    // also the one shared implementation for the trusted repository API.
    requirePluginDocumentVersion(transaction, expected)
    let revision = expected.revision + 1
    if (expected.revision == 0) {
        transaction.execute("INSERT INTO plugin_documents(thread_id,lane_id,namespace,document_key,revision,payload) VALUES(?,?,?,?,?,?)",
            [SqlParameter.Text(expected.threadId.value), SqlParameter.Text(expected.laneId.value), SqlParameter.Text(expected.namespace),
                SqlParameter.Text(expected.key), SqlParameter.Int64Value(revision), SqlParameter.Text(encodedNext)])
    } else {
        transaction.execute("UPDATE plugin_documents SET revision=?,payload=? WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=? AND revision=? AND payload=?",
            [SqlParameter.Int64Value(revision), SqlParameter.Text(encodedNext), SqlParameter.Text(expected.threadId.value),
                SqlParameter.Text(expected.laneId.value), SqlParameter.Text(expected.namespace), SqlParameter.Text(expected.key),
                SqlParameter.Int64Value(expected.revision), SqlParameter.Text(expected.encoded)])
        if (Int64.parse(transaction.query("SELECT changes()")[0].required(0)) != 1) {
            throw IllegalStateException("document CAS lost its transaction ownership") }
    }
    PluginDocumentSnapshot(expected.threadId, expected.laneId, expected.namespace, expected.key, revision, encodedNext)
}

func pluginDocumentExpected(intent: PluginDocumentIntent): PluginDocumentSnapshot {
    if (intent.referencesPayload) { throw IllegalStateException("reference document intent requires its retained payload transaction owner") }
    let binding = intent.binding()
    PluginDocumentSnapshot(ThreadId(httpIntentText(binding, "thread_id")), LaneId(httpIntentText(binding, "lane_id")),
        httpIntentText(binding, "namespace"), intent.key, intent.expectedRevision, intent.expectedJson)
}

// Additional scope proof within the existing ParentIntent transaction. The
// common caller already reconstructs Direct/Committed source and both complete
// normalized plans, not merely identifiers. It invokes this on admission,
// markExecuting, handoff and settlement. Reads are scoped just like mutations.
func requirePluginDocumentScope(transaction: SqliteTransaction, parentId: OperationId,
    runId: RunId, threadId: String, epoch: String, itemId: String,
    childPlan: NormalizedOperationPlan, settlementOnly: Bool,
    allocate: ?(Int64) -> LogicalJsonOwnerReservation): Unit {
    if(httpIntentText(childPlan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA){
        requirePluginRowJournalScope(transaction,parentId,runId,threadId,epoch,itemId,childPlan,settlementOnly,allocate);return}
    let intent = parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow()
    let binding = intent.binding()
    if (encodeStoredValue(intent.result()).size > 8388608) {
        throw IllegalStateException("complete document result exceeds durable Receipt codec bound") }
    if (httpIntentText(binding, "thread_id") != threadId || httpIntentText(binding, "run_id") != runId.value ||
        binding.field("epoch").getOrThrow().asNumberText() != epoch) {
        throw IllegalStateException("plugin document scope differs from its canonical parent") }
    let calls = transaction.query("SELECT payload FROM items WHERE id=? AND thread_id=?",
        [SqlParameter.Text(itemId), SqlParameter.Text(threadId)])
    if (calls.size != 1) { throw IllegalStateException("document has no exact canonical call") }
    match (decodeStoredThreadContent(calls[0].required(0))) {
        case ThreadItemContent.ToolCall(callId, _, _) => if (callId.value != httpIntentText(binding, "parent_call_id")) {
            throw IllegalStateException("document binding differs from its canonical parent call") }
        case _ => throw IllegalStateException("document source is not a canonical call")
    }
    let lanes = transaction.query("SELECT binding.lane_id FROM run_lane_bindings binding " +
        "JOIN runs actual ON actual.id=binding.run_id AND actual.thread_id=binding.thread_id " +
        "JOIN turns active ON active.id=actual.turn_id AND active.thread_id=actual.thread_id AND active.active_run_id=actual.id AND active.state='active' " +
        "JOIN item_tree_edges edge ON edge.thread_id=binding.thread_id AND edge.lane_id=binding.lane_id " +
        "JOIN lanes lane ON lane.thread_id=binding.thread_id AND lane.lane_id=binding.lane_id " +
        "WHERE binding.run_id=? AND binding.thread_id=? AND edge.item_id=? AND lane.status='open'",
        [SqlParameter.Text(runId.value), SqlParameter.Text(threadId), SqlParameter.Text(itemId)])
    if (lanes.size != 1 || lanes[0].required(0) != httpIntentText(binding, "lane_id")) {
        throw IllegalStateException("plugin document lane differs from its canonical source") }
    if(!settlementOnly){match(transaction.documentStorageBackend(httpIntentText(binding,"namespace"),intent.key)){
        case Some(backend)=>transaction.withBackendAllocationPhase({=>
            backend.requireParentFence(transaction,parentId,runId,intent)});case None=>()}}
    // Old obligations may be closed Unknown/never-handed Rejected after a
    // competing CAS; this must never authorize a new read or replacement.
    if (!settlementOnly) {
        if (intent.referencesPayload) { requireDocumentPayloadCurrent(transaction, intent, allocate) }
        else { requirePluginDocumentVersion(transaction, pluginDocumentExpected(intent)) }
    }
}

func settlePluginDocumentInTransaction(transaction: SqliteTransaction, runId: RunId, parent: OperationId,
    receipt: VNextOperationReceipt, plan: NormalizedOperationPlan,
    allocate: ?(Int64) -> LogicalJsonOwnerReservation, committer: ?PluginDocumentPayloadCommitter): Unit {
    if (plan.toolName != HOST_PLUGIN_DOCUMENT_TOOL) { return }
    if (!isPluginDocumentChildPlan(plan)) { throw IllegalStateException("invalid document settlement plan") }
    if (receipt.outcome != OperationOutcome.Completed) { return }
    let intent = parsePluginDocumentIntent(plan.canonicalArguments).value().getOrThrow()
    if (canonicalAgentValue(receipt.detail) != canonicalAgentValue(intent.result())) {
        throw IllegalStateException("document Receipt must describe the exact frozen result") }
    if (encodeStoredValue(receipt.detail).size > 8388608 || encodeStoredValue(receipt.verification).size > 8388608) {
        throw IllegalStateException("complete document Receipt exceeds durable codec bound") }
    let handoff = transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? " +
        "AND thread_id=? AND kind='operation_execution_handoff'", [SqlParameter.Text(receipt.operationId.value),
        SqlParameter.Text(runId.value), SqlParameter.Text(httpIntentText(intent.binding(), "thread_id"))])
    if (handoff.size != 1) { throw IllegalStateException("document has no actual child handoff") }
    match(transaction.documentStorageBackend(httpIntentText(intent.binding(),"namespace"),intent.key)){
        case Some(backend)=>
            transaction.withBackendAllocationPhase({=>backend.requireParentFence(transaction,parent,runId,intent)})
            transaction.authorizeBackendCommit(httpIntentText(intent.binding(),"namespace"),intent.key)
        case None=>()}
    if (intent.referencesPayload) {
        requireDocumentPayloadCurrent(transaction, intent, allocate)
        requireDocumentPayloadMetadata(transaction, intent.expectedPayload.getOrThrow())
        if (intent.compareExchange) {
            if (committer.isNone() || allocate.isNone()) { throw IllegalStateException("reference replacement requires its retained payload transaction owner") }
            let proof = SqlitePluginDocumentPayloadCommitProof(transaction, runId, parent, receipt.operationId, intent, allocate.getOrThrow())
            try {
                match (committer.getOrThrow().commit(proof)) {
                    case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
                if (!proof.didApply()) { throw IllegalStateException("payload committer did not consume the actual replacement proof") }
            } finally { proof.close() }
        }
        return
    }
    let expected = pluginDocumentExpected(intent)
    if (intent.compareExchange) {
        let _ = compareExchangePluginDocumentInTransaction(transaction, expected, intent.nextJson.getOrThrow())
    } else { requirePluginDocumentVersion(transaction, expected) }
    // No second journal: the caller now writes the already reserved Receipt
    // and operation state. Any later SQL failure rolls this CAS back as well.
}
