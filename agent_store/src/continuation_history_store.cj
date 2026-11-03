package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// A fork copies observed content, not the transient owner or consumed claim.
// This record is only written inside the new completed Thread's seed Tx after
// reloading its actual completed source. Once copied it survives source reset.
func insertContinuationHistoryCopy(tx: SqliteTransaction, item: ThreadItem): Unit {
    let source = item.provenance.continuationHistory.getOrThrow()
    if (!isContinuationHistoryDescription(item) || source.threadId == item.threadId.value) {
        throw IllegalStateException("continuation history copy requires a different completed source Thread") }
    let rows = tx.query("SELECT i.ordinal,i.payload,i.provenance,i.created_at_millis FROM items i " +
        "JOIN runs r ON r.id=? AND r.thread_id=i.thread_id AND r.turn_id=i.turn_id " +
        "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id AND t.user_item_id=i.id " +
        "WHERE i.id=? AND i.thread_id=? AND i.turn_id=? AND r.state='completed' AND t.state='completed' AND t.active_run_id IS NULL",
        [SqlParameter.Text(source.runId), SqlParameter.Text(source.itemId), SqlParameter.Text(source.threadId), SqlParameter.Text(source.turnId)])
    if (rows.size != 1) { throw IllegalStateException("continuation history source is missing or not completed") }
    let original = ThreadItem(ItemId(source.itemId), ThreadId(source.threadId), SemanticTurnId(source.turnId),
        Int64.parse(rows[0].required(0)), decodeStoredThreadContent(rows[0].required(1)),
        decodeStoredProvenance(rows[0].required(2)), createdAtMillis: Int64.parse(rows[0].required(3)))
    if (original.provenance.runId.isNone() || original.provenance.runId.getOrThrow().value != source.runId) {
        throw IllegalStateException("continuation history source Run changed") }
    let request = if (isContinuationInitiatorDescription(original)) { consumedContinuationRequest(tx, original) }
        else if (isContinuationHistoryDescription(original)) { continuationHistoryRequest(tx, original) }
        else { throw IllegalStateException("history source is not a verified continuation input") }
    if (modelPolicySha256Text(canonicalAgentValue(request)) != source.requestDigest) {
        throw IllegalStateException("continuation history source input changed") }
    tx.execute("INSERT INTO audit_events(thread_id,run_id,kind,payload,created_at_millis,commit_sequence) VALUES (?,?,?,?,?,0)",
        [SqlParameter.Text(item.threadId.value), SqlParameter.Text(item.provenance.runId.getOrThrow().value),
            SqlParameter.Text("host_continuation_history_v1"), SqlParameter.Text(encodeStoredValue(objectValue([
                ValueField("source", continuationHistorySourceValue(source)), ValueField("item_id", textValue(item.id.value)),
                ValueField("request", request)]))), SqlParameter.Int64Value(item.createdAtMillis)])
}

// No live scope, claim consumption, Run start or continuation permission is
// available from this API. It resolves already-copied historical model data.
public func continuationHistoryRequest(tx: SqliteTransaction, item: ThreadItem): AgentValue {
    if (!isContinuationHistoryDescription(item)) { throw IllegalStateException("continuation history description is missing") }
    let source = item.provenance.continuationHistory.getOrThrow()
    let rows = tx.query("SELECT i.payload,i.provenance,a.payload FROM items i " +
        "JOIN runs r ON r.id=? AND r.thread_id=i.thread_id AND r.turn_id=i.turn_id " +
        "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id AND t.user_item_id=i.id " +
        "JOIN audit_events a ON a.run_id=r.id AND a.thread_id=r.thread_id AND a.kind='host_continuation_history_v1' " +
        "WHERE i.id=? AND i.thread_id=? AND i.turn_id=? AND r.state='completed' AND t.state='completed' AND t.active_run_id IS NULL",
        [SqlParameter.Text(item.provenance.runId.getOrThrow().value), SqlParameter.Text(item.id.value),
            SqlParameter.Text(item.threadId.value), SqlParameter.Text(item.turnId.value)])
    if (rows.size != 1 || rows[0].required(0) != encodeStoredThreadContent(item.content) ||
        rows[0].required(1) != encodeStoredProvenance(item.provenance)) {
        throw IllegalStateException("continuation history lost its exact completed canonical Item") }
    let record = decodeStoredValue(rows[0].required(2))
    if (!httpIntentExactFields(record, ["source", "item_id", "request"]) ||
        httpIntentText(record, "item_id") != item.id.value ||
        encodeStoredValue(record.field("source").getOrThrow()) != encodeStoredValue(continuationHistorySourceValue(source)) ||
        modelPolicySha256Text(canonicalAgentValue(record.field("request").getOrThrow())) != source.requestDigest) {
        throw IllegalStateException("continuation history input proof changed") }
    record.field("request").getOrThrow()
}
