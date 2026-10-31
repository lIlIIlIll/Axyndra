package agent_store

import agent_domain.*
import agent_runtime.*

func rpcQueuedOriginalPayload113(value: QueuedRunInitiatorData113): String {
    encodeStoredValue(objectValue([ValueField("correlation_id", textValue(value.correlationId)),
        ValueField("kind", textValue(value.kind)), ValueField("text", textValue(value.input))]))
}
func requireActualRpcQueuedRow113(transaction: SqliteTransaction, value: QueuedRunInitiatorData113): Unit {
    // Full expected predicates run in the actual TX. Actual text/payload is
    // never projected into Cj, even if a writer corrupted it to an enormous BLOB.
    let rows = transaction.query("SELECT COUNT(*) FROM lane_inbox_entries WHERE id=? AND thread_id=? " +
        "AND lane_id=? AND kind='user_prompt' AND payload=? AND status='queued' AND claimed_step_id IS NULL",
        [SqlParameter.Text(value.entryId.value), SqlParameter.Text(value.threadId.value),
            SqlParameter.Text(value.laneId.value), SqlParameter.Text(rpcQueuedOriginalPayload113(value))])
    if (rows.size != 1 || rows[0].required(0) != "1") {
        throw IllegalStateException("actual queued input identity/content/status changed") }
}
func commitActualRpcQueuedInitiator113(transaction: SqliteTransaction, value: QueuedRunInitiatorData113,
    turn: TurnRecord, item: ThreadItem, step: StepId, inputPayment: LogicalJsonOwnerReservation): Unit {
    let bytes = rpcQueuedExpectedBytes113(value)
    let paid = inputPayment.deriveRetainedLease()
    try {
        paid.ensureRetainedPeak(131072 + bytes * 64)
        commitActualRpcQueuedInitiatorHelper113(transaction, value, turn, item, step)
    } finally { paid.close() }
}
// Expected codec locals and all prepared statements physically return from
// this helper BEFORE the distinct query lease is retired by the outer method.
func commitActualRpcQueuedInitiatorHelper113(transaction: SqliteTransaction, value: QueuedRunInitiatorData113,
    turn: TurnRecord, item: ThreadItem, step: StepId): Unit {
    if (value.threadId.value != turn.threadId.value || item.id.value != value.entryId.value) {
        throw IllegalStateException("actual queued initiator differs from its committed Turn") }
    match (item.content) {
        case ThreadItemContent.UserMessage(parts) =>
            if (parts.size != 1) { throw IllegalStateException("queued initiator has extra message parts") }
            match (parts[0]) {
                case ThreadMessagePart.Text(text) => if (text != value.input) {
                    throw IllegalStateException("queued initiator text changed") }
                case _ => throw IllegalStateException("queued initiator is not the actual text input") }
        case _ => throw IllegalStateException("queued initiator is not a user input") }
    requireActualRpcQueuedRow113(transaction, value)
    transaction.execute("UPDATE lane_inbox_entries SET status='claimed',claimed_step_id=?," +
        "revision=revision+1 WHERE id=? AND status='queued' AND claimed_step_id IS NULL",
        [SqlParameter.Text(step.value), SqlParameter.Text(value.entryId.value)])
    requireStoreChanged(transaction, "actual queued input was not claimed by the original Turn transaction")
}
func rpcQueuedExpectedBytes113(value: QueuedRunInitiatorData113): Int64 {
    var bytes: Int64 = 0
    for (size in [value.entryId.value.size, value.threadId.value.size, value.laneId.value.size,
        value.correlationId.size, value.kind.size, value.input.size]) {
        if (size > Int64.Max - bytes) { throw IllegalStateException("queued expected input extent overflow") }
        bytes += size }
    if (bytes > (Int64.Max - 131072) / 64) { throw IllegalStateException("queued expected codec invoice overflow") }
    bytes
}
// Only fixed vocabulary and a NULL boolean cross the DB boundary. Every
// identity and complete original payload still participates in the predicate.
func actualRpcQueuedStatus113(transaction: SqliteTransaction, value: QueuedRunInitiatorData113): String {
    let rows = transaction.query("SELECT CASE WHEN status IN ('queued','processing','claimed','applied','rejected') " +
        "THEN status ELSE 'changed' END,CASE WHEN claimed_step_id IS NULL THEN '0' ELSE '1' END " +
        "FROM lane_inbox_entries WHERE id=? AND thread_id=? AND lane_id=? AND kind='user_prompt' AND payload=?",
        [SqlParameter.Text(value.entryId.value), SqlParameter.Text(value.threadId.value),
            SqlParameter.Text(value.laneId.value), SqlParameter.Text(rpcQueuedOriginalPayload113(value))])
    if (rows.size != 1) { throw IllegalStateException("actual queued input enclosure/content changed") }
    let status = rows[0].required(0)
    if (status == "claimed" || (status == "applied" && rows[0].required(1) == "1")) {
        let owners = transaction.query("SELECT COUNT(*),COALESCE(SUM(CASE WHEN step.id=inbox.claimed_step_id " +
            "AND step.thread_id=? AND step.lane_id=? AND step.accepted_item_id=? AND run.thread_id=? " +
            "AND lane.lane_id=? AND item.thread_id=? AND item.payload=? THEN 1 ELSE 0 END),0) " +
            "FROM step_records step JOIN lane_inbox_entries inbox ON inbox.id=step.input_entry_id " +
            "JOIN runs run ON run.id=step.run_id JOIN run_lane_bindings lane ON lane.run_id=run.id " +
            "JOIN items item ON item.id=step.accepted_item_id WHERE step.input_entry_id=? " +
            "AND step.ordinal=0 AND step.turn_id=run.turn_id",
            [SqlParameter.Text(value.threadId.value),
                SqlParameter.Text(value.laneId.value), SqlParameter.Text(value.entryId.value),
                SqlParameter.Text(value.threadId.value), SqlParameter.Text(value.laneId.value),
                SqlParameter.Text(value.threadId.value), SqlParameter.Text(encodeStoredThreadContent(
                    ThreadItemContent.UserMessage([ThreadMessagePart.Text(value.input)]))),
                SqlParameter.Text(value.entryId.value)])
        if (owners.size != 1 || owners[0].required(0) != "1" || owners[0].required(1) != "1") {
            throw IllegalStateException("queued input lacks its actual matching Turn/Run/Step/Item") }
    } else if (rows[0].required(1) != "0" || !["queued", "processing", "applied", "rejected"].contains(status)) {
        throw IllegalStateException("queued input processing status changed") }
    status
}
