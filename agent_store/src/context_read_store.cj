package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

// All functions run inside their caller's existing SQLite transaction. There
// is no second fact store and the Item is never a fabricated Model Decision.
func contextReadEnclosure(transaction: SqliteTransaction, item: ThreadItem,
    epoch: Int64, allowCancelling: Bool, allowWaitingApproval!: Bool = false): AgentValue {
    let origin = match (item.provenance.directOrigin) { case Some(DirectCallOrigin.ContextRead(value)) => value
        case _ => throw IllegalStateException("context read has no typed origin") }
    if (item.kind != ItemKind.ToolCall || item.provenance.source != "direct_tool" ||
        item.provenance.runId.isNone() || item.provenance.operationId.isNone()) {
        throw IllegalStateException("context read has no exact canonical Operation source")
    }
    let run = item.provenance.runId.getOrThrow()
    let rows = transaction.query("SELECT r.epoch,r.skill_snapshot FROM runs r " +
        "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id " +
        "JOIN items initial ON initial.id=turn.user_item_id " +
        "WHERE r.id=? AND r.thread_id=? AND r.turn_id=? AND r.epoch=? " +
        "AND r.state IN (" + (if (allowCancelling) { "'running','cancelling'" } else if (allowWaitingApproval) { "'running','waiting_approval'" } else { "'running'" }) + ") " +
        "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id " +
        "AND turn.state='active'",
        [SqlParameter.Text(run.value), SqlParameter.Text(item.threadId.value), SqlParameter.Text(item.turnId.value), SqlParameter.Int64Value(epoch)])
    if (rows.size != 1 || contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(rows[0].required(1)))) != origin.projectionDigest) {
        throw IllegalStateException("context read no longer owns the same Run projection")
    }
    requireUserOrConsumedContinuation(transaction, item.threadId, item.turnId, run, epoch)
    contextReadEvidence(item, epoch)
}

func contextReadEvidence(item: ThreadItem, epoch: Int64): AgentValue {
    let origin = match (item.provenance.directOrigin.getOrThrow()) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("context read origin missing") }
    let run = item.provenance.runId.getOrThrow()
    let payload = encodeStoredThreadContent(item.content)
    objectValue([ValueField("origin", contextReadOriginValue(origin)),
        ValueField("thread_id", textValue(item.threadId.value)), ValueField("turn_id", textValue(item.turnId.value)),
        ValueField("run_id", textValue(run.value)), ValueField("epoch", textValue(epoch.toString())),
        ValueField("tool_call_item_id", textValue(item.id.value)),
        ValueField("operation_id", textValue(item.provenance.operationId.getOrThrow().value)),
        ValueField("call_digest", textValue(modelPolicySha256Text(payload)))])
}

func recordContextReadAdmission(transaction: SqliteTransaction, transition: ThreadTransition, item: ThreadItem): Unit {
    if (!isContextReadItem(item)) { return }
    let origin = match (item.provenance.directOrigin.getOrThrow()) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("context read origin missing") }
    let evidence = contextReadEnclosure(transaction, item, transition.before.activeEpoch, false)
    let run = item.provenance.runId.getOrThrow()
    if (!transaction.query("SELECT id FROM model_attempts WHERE run_id=? AND (lifecycle IN ('created','streaming') OR completed_at_millis IS NULL)",
        [SqlParameter.Text(run.value)]).isEmpty() || !transaction.query(
            "SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
            "WHERE a.run_id=? AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NULL",
            [SqlParameter.Text(run.value)]).isEmpty()) { throw IllegalStateException("context read cannot run during an unsettled model Attempt") }
    if (!transaction.query("SELECT id FROM operations WHERE run_id=? AND state!='committed'",
        [SqlParameter.Text(run.value)]).isEmpty()) { throw IllegalStateException("context read preflight requires settled prior Operations") }
    if (!transaction.query("SELECT id FROM audit_events WHERE run_id=? AND kind='context_read_admitted' AND payload=?",
        [SqlParameter.Text(run.value), SqlParameter.Text(encodeStoredValue(evidence))]).isEmpty()) {
        throw IllegalStateException("context read admission is already committed")
    }
    let pending = HashSet<String>()
    var parentPending = false
    for (row in transaction.query("SELECT id,payload FROM items WHERE thread_id=? AND turn_id=? AND id!=? " +
        "AND kind IN ('tool_call','tool_result') ORDER BY ordinal", [SqlParameter.Text(item.threadId.value),
        SqlParameter.Text(item.turnId.value), SqlParameter.Text(item.id.value)])) {
        match (decodeStoredThreadContent(row.required(1))) {
            case ThreadItemContent.ToolCall(id, _, _) =>
                pending.add(id.value)
                if (row.required(0) == origin.parentCallItemId) { parentPending = true }
            case ThreadItemContent.ToolResult(id, _, _, _, _) =>
                pending.remove(id.value)
            case _ => ()
        }
    }
    if (origin.parentCallItemId == "") {
        if (!pending.isEmpty()) { throw IllegalStateException("context read requires a parent inside a pending tool round") }
    } else if (origin.parentKind == "direct") {
        let parents = transaction.query("SELECT item.payload,item.provenance FROM items item WHERE item.id=? " +
            "AND item.thread_id=? AND item.turn_id=? AND item.kind='tool_call' " +
            "AND NOT EXISTS(SELECT 1 FROM operations op WHERE op.tool_call_item_id=item.id) " +
            "AND NOT EXISTS(SELECT 1 FROM canonical_decision_items c WHERE c.item_id=item.id) " +
            "AND NOT EXISTS(SELECT 1 FROM decision_operations d WHERE d.operation_id=?)",
            [SqlParameter.Text(origin.parentCallItemId), SqlParameter.Text(item.threadId.value),
                SqlParameter.Text(item.turnId.value), SqlParameter.Text(origin.parentOperationId)])
        if (parents.size != 1 || !parentPending) { throw IllegalStateException("context read has no unprepared Direct parent") }
        let provenance = decodeStoredProvenance(parents[0].required(1))
        if (provenance.source != "direct_tool" || provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
            provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != origin.parentOperationId ||
            !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect)) {
            throw IllegalStateException("context read Direct parent has ambiguous origin")
        }
        match (decodeStoredThreadContent(parents[0].required(0))) {
            case ThreadItemContent.ToolCall(id, _, _) => if (!pending.contains(id.value)) { throw IllegalStateException("context read Direct parent already settled") }
            case _ => throw IllegalStateException("context read Direct parent is not a call")
        }
    } else {
        let parents = transaction.query("SELECT item.payload FROM items item " +
            "JOIN canonical_decision_items c ON c.item_id=item.id JOIN model_decisions d ON d.id=c.decision_id " +
            "JOIN model_attempts a ON a.id=d.attempt_id JOIN model_decision_blocks block ON block.id=c.decision_block_id AND block.decision_id=d.id " +
            "WHERE d.id=? AND block.scoped_tool_call_id=? AND item.id=? AND item.thread_id=? AND item.turn_id=? AND item.kind='tool_call' " +
            "AND a.run_id=? AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL " +
            "AND NOT EXISTS(SELECT 1 FROM operations op WHERE op.tool_call_item_id=item.id)",
            [SqlParameter.Text(origin.parentDecisionId), SqlParameter.Text(origin.parentScopedCallId),
                SqlParameter.Text(origin.parentCallItemId), SqlParameter.Text(item.threadId.value),
                SqlParameter.Text(item.turnId.value), SqlParameter.Text(run.value)])
        if (parents.size != 1 || !parentPending) { throw IllegalStateException("context read has no unprepared committed parent") }
        match (decodeStoredThreadContent(parents[0].required(0))) {
            case ThreadItemContent.ToolCall(id, _, _) => if (!pending.contains(id.value)) { throw IllegalStateException("context read parent already settled") }
            case _ => throw IllegalStateException("context read parent is not a call")
        }
    }
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES (?,?,?,'context_read_admitted',?,?)", [SqlParameter.Text(item.threadId.value), SqlParameter.Text(run.value),
        SqlParameter.Text(item.provenance.operationId.getOrThrow().value), SqlParameter.Text(encodeStoredValue(evidence)),
        SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())])
}

func requireContextReadOriginBinding(transaction: SqliteTransaction, operation: OperationId, run: RunId,
    itemId: ItemId, allowCancelling: Bool, allowWaitingApproval!: Bool = false): Unit {
    let rows = transaction.query("SELECT item.thread_id,item.turn_id,item.ordinal,item.payload,item.provenance,item.created_at_millis,r.epoch " +
        "FROM items item JOIN runs r ON r.id=? WHERE item.id=? AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id",
        [SqlParameter.Text(run.value), SqlParameter.Text(itemId.value)])
    if (rows.size != 1) { throw IllegalStateException("context read canonical enclosure missing") }
    let row = rows[0]
    let item = ThreadItem(itemId, ThreadId(row.required(0)), SemanticTurnId(row.required(1)),
        parseStoreInt(row.required(2), "context read ordinal"), decodeStoredThreadContent(row.required(3)),
        decodeStoredProvenance(row.required(4)), createdAtMillis: parseStoreInt(row.required(5), "context read time"))
    if (item.provenance.operationId.isNone() || item.provenance.operationId.getOrThrow().value != operation.value ||
        item.provenance.runId.isNone() || item.provenance.runId.getOrThrow().value != run.value) {
        throw IllegalStateException("context read exact Operation binding changed")
    }
    let expected = encodeStoredValue(contextReadEnclosure(transaction, item, parseStoreInt(row.required(6), "context read epoch"), allowCancelling, allowWaitingApproval: allowWaitingApproval))
    let rows2 = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? " +
        "AND thread_id=? AND kind='context_read_admitted'", [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(item.threadId.value)])
    if (rows2.size != 1 || rows2[0].required(0) != expected) { throw IllegalStateException("context read admission changed or was never committed") }
}

func requireContextReadPlan(transaction: SqliteTransaction, itemId: ItemId, plan: NormalizedOperationPlan): Unit {
    let rows = transaction.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(itemId.value)])
    if (rows.size != 1) { throw IllegalStateException("context read source item missing") }
    match (decodeStoredProvenance(rows[0].required(0)).directOrigin) {
        case Some(DirectCallOrigin.ContextRead(origin)) =>
            if (!isContextReadPlan(plan) || contextReadPlanDigest(plan) != origin.readPlanDigest) {
                throw IllegalStateException("context read Operation no longer has its frozen read-only plan")
            }
        case _ => if (plan.toolName == HOST_CONTEXT_READ_TOOL) { throw IllegalStateException("context read port requires its own typed source") }
    }
}

func requireContextReadFact(transaction: SqliteTransaction, operation: OperationId, run: RunId): ContextReadFact {
    let rows = transaction.query("SELECT call.id,call.thread_id,call.turn_id,call.ordinal,call.payload,call.provenance,call.created_at_millis," +
        "r.epoch,o.normalized_plan,receipt.id,receipt.detail,result.id,result.payload " +
        "FROM operations o JOIN runs r ON r.id=o.run_id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.normalized_plan=o.normalized_plan " +
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
        "JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id AND result.turn_id=r.turn_id " +
        "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=r.id AND handoff.thread_id=r.thread_id AND handoff.kind='operation_execution_handoff' " +
        "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND receipt.outcome='completed' " +
        "AND call.kind='tool_call' AND result.kind='tool_result' " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions d WHERE d.operation_id=o.id) " +
        "AND NOT EXISTS(SELECT 1 FROM decision_operations d WHERE d.operation_id=o.id) " +
        "AND NOT EXISTS(SELECT 1 FROM canonical_decision_items c WHERE c.item_id=call.id)",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("context read has no unique Completed canonical result and handoff") }
    let row = rows[0]
    let item = ThreadItem(ItemId(row.required(0)), ThreadId(row.required(1)), SemanticTurnId(row.required(2)),
        parseStoreInt(row.required(3), "context read ordinal"), decodeStoredThreadContent(row.required(4)),
        decodeStoredProvenance(row.required(5)), createdAtMillis: parseStoreInt(row.required(6), "context read time"))
    let origin = match (item.provenance.directOrigin.getOrThrow()) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("fact is not a canonical context read") }
    if (item.provenance.source != "direct_tool" || item.provenance.runId.getOrThrow().value != run.value ||
        item.provenance.operationId.getOrThrow().value != operation.value) { throw IllegalStateException("context read fact source changed") }
    requireContextReadPlan(transaction, item.id, decodeOperationPlan(row.required(8)))
    let evidence = encodeStoredValue(contextReadEvidence(item, parseStoreInt(row.required(7), "context read epoch")))
    let audits = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? " +
        "AND thread_id=? AND kind='context_read_admitted'", [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(item.threadId.value)])
    if (audits.size != 1 || audits[0].required(0) != evidence) { throw IllegalStateException("context read fact admission changed") }
    let callId = match (item.content) { case ThreadItemContent.ToolCall(id, _, _) => id.value
        case _ => throw IllegalStateException("context read fact source kind changed") }
    match (decodeStoredThreadContent(row.required(12))) {
        case ThreadItemContent.ToolResult(id, operationId, receiptId, output, isError) =>
            if (id.value != callId || operationId.value != operation.value || receiptId != row.required(9) || isError ||
                canonicalAgentValue(output) != canonicalAgentValue(decodeStoredValue(row.required(10)))) {
                throw IllegalStateException("context read result and Receipt disagree")
            }
            ContextReadFact(operation, run, item.id, ItemId(row.required(11)), receiptId, origin, output)
        case _ => throw IllegalStateException("context read fact result kind changed")
    }
}

// Data provenance is not an effect grant. This validates only reads consumed
// by this exact root before its normal capabilities, approval and handoff.
// Historical load remains available; only new consumption needs a live owner.
// This helper is deliberately not imposed on cancellation/late settlement.
func requireContextReadFactConsumption(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, parentItem: ItemId, plan: NormalizedOperationPlan): Unit {
    requireContextReadFactConsumptionFields(transaction, operation, run, parentItem, plan.toolName, plan.contextReadFacts)
}

// Shared exact canonical parent/fact validation for pre-plan immutable payload
// staging. No plan or approval is fabricated merely to reuse this predicate.
func requireContextReadFactConsumptionFields(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, parentItem: ItemId, toolName: String, links: Array<ContextReadFactLink>): Unit {
    if (links.isEmpty()) { return }
    let parents = transaction.query("SELECT item.payload,item.provenance,item.ordinal,r.thread_id,r.turn_id,r.epoch,r.skill_snapshot " +
        "FROM items item JOIN runs r ON item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
        "JOIN threads thread ON thread.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "WHERE r.id=? AND item.id=? AND item.kind='tool_call' AND r.state IN ('running','waiting_external') " +
        "AND r.finished_at_millis IS NULL AND thread.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions child WHERE child.operation_id=?)",
        [SqlParameter.Text(run.value), SqlParameter.Text(parentItem.value), SqlParameter.Text(operation.value)])
    if (parents.size != 1) { throw IllegalStateException("context read consumption requires its active canonical root") }
    let parent = parents[0]
    let callId = match (decodeStoredThreadContent(parent.required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) =>
            if (name != toolName) { throw IllegalStateException("context read cannot be transferred to another tool") }
            id.value
        case _ => throw IllegalStateException("context read parent is not a canonical call")
    }
    for (result in transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(parent.required(3)), SqlParameter.Text(parent.required(4))])) {
        match (decodeStoredThreadContent(result.required(0))) {
            case ThreadItemContent.ToolResult(id, _, _, _, _) => if (id.value == callId) {
                throw IllegalStateException("context read parent is already settled") }
            case _ => ()
        }
    }
    let projection = contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(parent.required(6))))
    for (link in links) {
        let fact = requireContextReadFact(transaction, link.operationId, run)
        if (link.runId.value != run.value || canonicalAgentValue(link.toValue()) != canonicalAgentValue(fact.reference()) ||
            fact.origin.parentCallItemId != parentItem.value || fact.origin.projectionDigest != projection) {
            throw IllegalStateException("context read fact no longer matches this Run, projection and exact parent")
        }
        let order = transaction.query("SELECT call.ordinal,result.ordinal FROM items call JOIN items result ON result.id=? " +
            "AND result.thread_id=call.thread_id AND result.turn_id=call.turn_id WHERE call.id=? AND call.thread_id=? AND call.turn_id=?",
            [SqlParameter.Text(fact.resultItemId.value), SqlParameter.Text(fact.sourceItemId.value),
                SqlParameter.Text(parent.required(3)), SqlParameter.Text(parent.required(4))])
        if (order.size != 1 || parseStoreInt(order[0].required(0), "read order") <= parseStoreInt(parent.required(2), "parent order") ||
            parseStoreInt(order[0].required(1), "read result order") <= parseStoreInt(order[0].required(0), "read order")) {
            throw IllegalStateException("context read facts do not follow their canonical parent")
        }
        let origin = fact.origin
        if (origin.parentKind == "direct") {
            let provenance = decodeStoredProvenance(parent.required(1))
            if (origin.parentOperationId != operation.value || provenance.source != "direct_tool" ||
                provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
                provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operation.value ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect) ||
                !transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
                    [SqlParameter.Text(parentItem.value)]).isEmpty()) {
                throw IllegalStateException("context read Direct parent binding changed")
            }
        } else if (origin.parentKind == "committed") {
            let expectedOperation = "operation-" + origin.parentDecisionId + "-" + origin.parentScopedCallId
            let canonical = transaction.query("SELECT c.item_id FROM canonical_decision_items c " +
                "JOIN model_decisions d ON d.id=c.decision_id JOIN model_attempts a ON a.id=d.attempt_id " +
                "JOIN model_decision_blocks b ON b.id=c.decision_block_id AND b.decision_id=d.id " +
                "WHERE c.item_id=? AND d.id=? AND b.scoped_tool_call_id=? AND a.run_id=? " +
                "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
                [SqlParameter.Text(parentItem.value), SqlParameter.Text(origin.parentDecisionId),
                    SqlParameter.Text(origin.parentScopedCallId), SqlParameter.Text(run.value)])
            if (operation.value != expectedOperation || canonical.size != 1) {
                throw IllegalStateException("context read committed parent binding changed")
            }
        } else { throw IllegalStateException("safe-cut context data cannot be repurposed as a pending tool read") }
    }
}

// Recheck the same canonical handoff inside the already owned transaction.
// Shared by Store reads and its internal payload proof; no new authority.
func requireContextReadExecutingInTransaction(transaction: SqliteTransaction,
    source: DirectToolCallRef, plan: NormalizedOperationPlan): Unit {
            requireContextReadOriginBinding(transaction, source.operationId, source.runId, source.canonicalItemId, false)
            requireContextReadPlan(transaction, source.canonicalItemId, plan)
            let rows = transaction.query("SELECT o.normalized_plan FROM operations o " +
                "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.normalized_plan=o.normalized_plan " +
                "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
                "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=o.run_id AND handoff.thread_id=? " +
                "AND handoff.kind='operation_execution_handoff' WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND o.state='executing' " +
                "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=o.id)",
                [SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.operationId.value), SqlParameter.Text(source.runId.value),
                    SqlParameter.Text(source.canonicalItemId.value)])
            if (rows.size != 1 || rows[0].required(0) != encodeOperationPlan(plan)) {
                throw IllegalStateException("context read no longer has an executing canonical handoff")
            }
}

