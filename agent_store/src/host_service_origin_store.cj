package agent_store

import agent_domain.*
import agent_runtime.*
import std.time.*
import yjson.*
import yjson_support.*

// Origin is evidence, not a grant. All callers hold the existing operation
// transaction; no second database or independent admission registry is used.
func requireHostServiceOriginBinding(transaction: SqliteTransaction,
    operationId: OperationId, runId: RunId, itemId: ItemId,
    bindIfMissing!: Bool = false, expectedOrigin!: ?DirectCallOrigin = None,
    allowCancellingSettlement!: Bool = false): Unit {
    let rows = transaction.query(
        "SELECT call.provenance,call.payload,runs.thread_id,runs.turn_id,runs.epoch," +
        "runs.state,threads.active_turn_id,initial.kind,initial.provenance,initial.id " +
        "FROM runs JOIN threads ON threads.id=runs.thread_id JOIN turns ON turns.id=runs.turn_id " +
        "JOIN items call ON call.id=? AND call.thread_id=runs.thread_id AND call.turn_id=runs.turn_id " +
        "JOIN items initial ON initial.id=turns.user_item_id AND initial.thread_id=runs.thread_id AND initial.turn_id=runs.turn_id " +
        "WHERE runs.id=? AND call.kind='tool_call'", [SqlParameter.Text(itemId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("Direct origin has no unique canonical enclosure") }
    let row = rows[0]
    let provenance = decodeStoredProvenance(row.required(0))
    let initial = decodeStoredProvenance(row.required(8))
    let origin = effectiveDirectCallOrigin(provenance)
    match (expectedOrigin) {
        case Some(value) => if (!sameDirectCallOrigin(value, origin)) {
            throw IllegalStateException("sealed Direct source differs from persisted origin")
        }
        case None => ()
    }
    match (origin) {
        case DirectCallOrigin.ManagedJob(value) =>
            requireManagedJobOriginBinding(transaction, operationId, runId, itemId, value,
                bindIfMissing: bindIfMissing, allowCancellingSettlement: allowCancellingSettlement)
            return
        case DirectCallOrigin.ContextRead(_) =>
            requireContextReadOriginBinding(transaction, operationId, runId, itemId, allowCancellingSettlement)
            return
        case _ => ()
    }
    if (!transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_managed_job_origin_bound'",
        [SqlParameter.Text(operationId.value)]).isEmpty()) {
        throw IllegalStateException("persisted Task origin cannot be downgraded to another Direct source")
    }
    let audits = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind='operation_host_origin_bound'",
        [SqlParameter.Text(operationId.value)])
    let service = match (origin) { case DirectCallOrigin.HostService(_) => true; case _ => false }
    let external = match (origin) { case DirectCallOrigin.External(_) => true; case _ => false }
    if (!service && !external && initial.source != "host_service" && initial.source != "external" && initial.directOrigin.isNone()) {
        if (!audits.isEmpty()) { throw IllegalStateException("persisted host service origin cannot be downgraded") }
        return
    }
    if ((!service && !external) || row.required(7) != "system_note" ||
        initial.source != (if (external) { "external" } else { "host_service" }) ||
        initial.runId.isNone() || initial.runId.getOrThrow().value != runId.value || initial.operationId.isSome() ||
        !sameDirectCallOrigin(origin, effectiveDirectCallOrigin(initial)) ||
        provenance.source != "direct_tool" || provenance.runId.isNone() || provenance.runId.getOrThrow().value != runId.value ||
        provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operationId.value ||
        !(row.required(5) == "running" ||
            (allowCancellingSettlement && row.required(5) == "cancelling")) ||
        row.required(6) != row.required(3)) {
        throw IllegalStateException("host service ToolCall does not own the exact active initiator and origin")
    }
    match (origin) {
        case DirectCallOrigin.External(value) =>
            if (value.threadId.value != row.required(2) || (!allowCancellingSettlement &&
                value.expiresAtMillis <= DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())) {
                throw IllegalStateException("external origin Thread or expiry differs from its active enclosure")
            }
            let call = match (decodeStoredThreadContent(row.required(1))) {
                case ThreadItemContent.ToolCall(id, name, arguments) => ToolCall(id.value, name, arguments)
                case _ => throw IllegalStateException("external request is not a canonical ToolCall")
            }
            if (externalToolCallDigest(call) != value.requestDigest) {
                throw IllegalStateException("external request bytes differ from the sealed received request")
            }
            // Numeric/text/null request identity and principal/connection/export
            // bindings are inside the immutable audit below, never SQL grants.
        case _ => ()
    }
    let evidence = encodeStoredValue(objectValue([
        ValueField("origin", directCallOriginValue(origin)), ValueField("thread_id", textValue(row.required(2))),
        ValueField("turn_id", textValue(row.required(3))), ValueField("run_id", textValue(runId.value)),
        ValueField("epoch", textValue(row.required(4))), ValueField("initiator_item_id", textValue(row.required(9))),
        ValueField("tool_call_item_id", textValue(itemId.value)), ValueField("operation_id", textValue(operationId.value)),
        ValueField("call_digest", textValue(modelPolicySha256Text(row.required(1))))
    ]))
    if (audits.isEmpty() && bindIfMissing) {
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
            "VALUES (?,?,?,'operation_host_origin_bound',?,?)", [SqlParameter.Text(row.required(2)),
            SqlParameter.Text(runId.value), SqlParameter.Text(operationId.value), SqlParameter.Text(evidence),
            SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())])
    } else if (audits.size != 1 || audits[0].required(0) != evidence) {
        throw IllegalStateException("host service origin evidence is missing or changed after preparation")
    }
}

func requireOperationHostOrigin(transaction: SqliteTransaction, operationId: OperationId, runId: RunId): Unit {
    let rows = transaction.query("SELECT operation.tool_call_item_id,COALESCE(derived.parent_operation_id,operation.id) " +
        "FROM operations operation LEFT JOIN derived_operation_admissions derived ON derived.operation_id=operation.id " +
        "WHERE operation.id=? AND operation.run_id=?", [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("Operation origin enclosure is missing") }
    let canonicalRoot = verifiedReadonlyOperationRoot(transaction, operationId, runId,
        OperationId(rows[0].required(1)))
    requireHostServiceOriginBinding(transaction, canonicalRoot, runId, ItemId(rows[0].required(0)))
    let parent = transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(canonicalRoot.value), SqlParameter.Text(runId.value)])
    if (parent.size != 1) { throw IllegalStateException("payload parent enclosure is missing") }
    let actualPlan = decodeOperationPlan(parent[0].required(0))
    requireServicePayloadPlan(transaction, runId, ItemId(rows[0].required(0)), actualPlan)
    requireContextReadPlan(transaction, ItemId(rows[0].required(0)), actualPlan)
    requireManagedJobPlan(transaction, ItemId(rows[0].required(0)), actualPlan)
    requireContextReadFactConsumption(transaction, canonicalRoot, runId, ItemId(rows[0].required(0)), actualPlan)
}

// Called inside each actual pre-effect transaction. A recovered description
// or old primitive-ID entry cannot advance an External operation. Liveness is
// checked before entering SQL (avoids Runtime-lock / Store-lock inversion).
func requireExternalOperationSource(transaction: SqliteTransaction, operationId: OperationId,
    runId: RunId, source: ?OperationRootSource): Unit {
    let rows = transaction.query("SELECT item.provenance,runs.thread_id,runs.turn_id,runs.epoch," +
        "COALESCE(derived.parent_operation_id,operation.id),item.id FROM operations operation " +
        "JOIN runs ON runs.id=operation.run_id JOIN items item ON item.id=operation.tool_call_item_id " +
        "LEFT JOIN derived_operation_admissions derived ON derived.operation_id=operation.id " +
        "WHERE operation.id=? AND operation.run_id=?", [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("operation source enclosure is missing") }
    let canonicalRoot = verifiedReadonlyOperationRoot(transaction, operationId, runId,
        OperationId(rows[0].required(4)))
    let origin = effectiveDirectCallOrigin(decodeStoredProvenance(rows[0].required(0)))
    match (origin) {
        case DirectCallOrigin.External(_) | DirectCallOrigin.ContextRead(_) | DirectCallOrigin.ManagedJob(_) =>
            let root = match (source) {
                case Some(OperationRootSource.Direct(value)) => value
                case _ => throw IllegalStateException("External execution requires the live sealed Direct root")
            }
            if (!sameDirectCallOrigin(root.origin, origin) || root.runId.value != runId.value ||
                root.threadId.value != rows[0].required(1) || root.turnId.value != rows[0].required(2) ||
                root.epoch.toString() != rows[0].required(3) || root.operationId.value != canonicalRoot.value ||
                root.canonicalItemId.value != rows[0].required(5)) {
                throw IllegalStateException("External execution source differs from canonical operation ancestry")
            }
        case _ => match (source) {
            case Some(OperationRootSource.Direct(root)) => match (root.origin) {
                case DirectCallOrigin.External(_) | DirectCallOrigin.ContextRead(_) | DirectCallOrigin.ManagedJob(_) => throw IllegalStateException("sealed source cannot be downgraded")
                case _ => ()
            }
            case _ => ()
        }
    }
}

func validateExternalStoreSource(source: ?OperationRootSource): Result<Unit> {
    match (source) {
        case Some(OperationRootSource.Direct(root)) => root.validateLiveSource()
        case _ => Result.Ok(())
    }
}
