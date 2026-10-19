package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Read, hash and discard within one paid scope. No raw document escapes the
// callback and the following key cannot reuse this reservation while bytes are
// retained. This is allocation accounting, never a namespace/source grant.
func requireDocumentPayloadCurrent(transaction: SqliteTransaction, intent: PluginDocumentIntent,
    allocate: ?(Int64) -> LogicalJsonOwnerReservation): Unit {
    if (!intent.referencesPayload || allocate.isNone()) { throw IllegalStateException("document payload accounting owner missing") }
    let expected = intent.expectedPayload.getOrThrow()
    let binding = intent.binding()
    let parameters = [SqlParameter.Text(httpIntentText(binding, "thread_id")), SqlParameter.Text(httpIntentText(binding, "lane_id")),
        SqlParameter.Text(httpIntentText(binding, "namespace")), SqlParameter.Text(intent.key)]
    transaction.withBackendAllocationPhase({=>
        let size = queryPluginDocumentRows(transaction,"SELECT revision,length(CAST(payload AS BLOB)) FROM plugin_documents " +
            "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?", parameters)
        if ((intent.expectedRevision == 0 && !size.isEmpty()) || (intent.expectedRevision > 0 &&
            (size.size != 1 || size[0].required(0) != intent.expectedRevision.toString() || size[0].required(1) != expected.bytes.toString()))) {
            throw IllegalStateException("document payload changed before bounded allocation") }
    })
    let lease = allocate.getOrThrow()(max(1, expected.bytes))
    try {
        transaction.withBackendAllocationPhase({=>
            let rows = queryPluginDocumentRows(transaction,"SELECT revision,payload,length(CAST(payload AS BLOB)) FROM plugin_documents " +
                "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?", [
                    SqlParameter.Text(httpIntentText(binding, "thread_id")), SqlParameter.Text(httpIntentText(binding, "lane_id")),
                    SqlParameter.Text(httpIntentText(binding, "namespace")), SqlParameter.Text(intent.key)])
            if (intent.expectedRevision == 0) {
                if (!rows.isEmpty() || expected.bytes != 4 || expected.digest != modelPolicySha256Text("null")) {
                    throw IllegalStateException("document payload absence changed") }
            } else if (rows.size != 1 || rows[0].required(0) != intent.expectedRevision.toString() ||
                rows[0].required(2) != expected.bytes.toString() || rows[0].required(1).size != expected.bytes ||
                modelPolicySha256Text(rows[0].required(1)) != expected.digest) {
                throw IllegalStateException("document payload revision or original bytes changed")
            }
        })
    } finally { lease.close() }
}

func documentPayloadParentOperation(fact: ContextReadFact): OperationId {
    if (fact.origin.parentKind == "direct" && fact.origin.parentOperationId != "") {
        return OperationId(fact.origin.parentOperationId) }
    if (fact.origin.parentKind == "committed" && fact.origin.parentDecisionId != "" && fact.origin.parentScopedCallId != "") {
        return OperationId("operation-" + fact.origin.parentDecisionId + "-" + fact.origin.parentScopedCallId) }
    throw IllegalStateException("document payload requires its actual pending Tool parent")
}

func requireDocumentPayloadFact(transaction: SqliteTransaction, run: RunId, parentItem: ItemId,
    link: ContextReadFactLink, intent: PluginDocumentIntent): ContextReadFact {
    if (!intent.referencesPayload) { throw IllegalStateException("document payload fact cannot authorize inline intent") }
    let fact = requireContextReadFact(transaction, link.operationId, run)
    let binding = intent.binding()
    let parent = documentPayloadParentOperation(fact)
    requireContextReadFactConsumptionFields(transaction, parent, run, parentItem,
        httpIntentText(binding, "contribution"), [link])
    let plans = transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?", [
        SqlParameter.Text(fact.operationId.value), SqlParameter.Text(run.value)])
    if (plans.size != 1) { throw IllegalStateException("document payload has no original read plan") }
    let read = decodeOperationPlan(plans[0].required(0))
    let request = read.canonicalArguments
    let data = fact.output()
    if (!isContextReadPlan(read) || !pluginDocumentReadAuthority(read) ||
        httpIntentText(request, "schema") != PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA ||
        canonicalAgentValue(request.field("binding").getOrThrow()) != canonicalAgentValue(binding) ||
        !pluginDocumentReadResultValid(data, request) || fact.origin.parentCallItemId != parentItem.value ||
        link.runId.value != run.value || canonicalAgentValue(link.toValue()) != canonicalAgentValue(fact.reference())) {
        throw IllegalStateException("document payload differs from the exact Completed read") }
    var found = false
    for (item in data.field("documents").getOrThrow().items where httpIntentText(item, "key") == intent.key) {
        if (found || item.field("revision").getOrThrow().asNumberText() != intent.expectedRevision.toString() ||
            canonicalAgentValue(item.field("payload").getOrThrow()) != canonicalAgentValue(intent.expectedPayload.getOrThrow().value())) {
            throw IllegalStateException("document payload is not the exact observed key and revision") }
        found = true
    }
    if (!found) { throw IllegalStateException("document payload key was not observed") }
    requireDocumentPayloadMetadata(transaction, intent.expectedPayload.getOrThrow())
    fact
}

func documentPayloadPreparedEvidence(fact: ContextReadFact, intent: PluginDocumentIntent): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.document-payload-prepared/v1")),
        ValueField("parent_item_id", textValue(fact.origin.parentCallItemId)),
        ValueField("parent_operation_id", textValue(documentPayloadParentOperation(fact).value)),
        ValueField("fact", fact.reference()), ValueField("intent", intent.toValue())])
}

// Product calls this with its artifact lock already held, the same immediate
// transaction that publishes metadata, and the actual writer/file verifier.
// This pins data for one pending canonical call; it creates no Operation,
// approval, handoff or permission. No worker can invoke this Store primitive.
public func retainPreparedPluginDocumentPayload(transaction: SqliteTransaction,
    link: ContextReadFactLink, value: AgentValue,
    allocate: (Int64) -> LogicalJsonOwnerReservation, verifyContent: () -> Result<Unit>): Result<Unit> {
    try {
        let intent = parsePluginDocumentIntent(value).value().getOrThrow()
        if (!intent.referencesPayload || !intent.compareExchange) { throw IllegalStateException("replacement payload intent required") }
        let initial = requireContextReadFact(transaction, link.operationId, link.runId)
        let parentItem = ItemId(initial.origin.parentCallItemId)
        let fact = requireDocumentPayloadFact(transaction, link.runId, parentItem, link, intent)
        if (!transaction.query("SELECT id FROM operations WHERE tool_call_item_id=?", [SqlParameter.Text(parentItem.value)]).isEmpty()) {
            throw IllegalStateException("document payload cannot be replaced after parent preparation") }
        requireDocumentPayloadCurrent(transaction, intent, Some(allocate))
        requireDocumentPayloadMetadata(transaction, intent.nextPayload.getOrThrow())
        match (verifyContent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let encoded = encodeStoredValue(documentPayloadPreparedEvidence(fact, intent))
        if(encoded.size>65536){throw IllegalStateException("document preparation witness exceeds its fixed shape bound")}
        let parentOperation=documentPayloadParentOperation(fact)
        // This is the real pending call's already-reserved ID, not an inserted
        // Operation or handoff. kind distinguishes this preparatory GC pin.
        let prior = transaction.query("SELECT id,length(CAST(payload AS BLOB)) FROM audit_events WHERE thread_id=? AND run_id=? " +
            "AND operation_id=? AND kind='plugin_document_payload_prepared' ORDER BY id LIMIT 9", [SqlParameter.Text(httpIntentText(intent.binding(), "thread_id")),
                SqlParameter.Text(link.runId.value),SqlParameter.Text(parentOperation.value)])
        let count=prior.size
        if(count>8){throw IllegalStateException("document parent preparation history exceeded")}
        var same: Int64 = 0
        for (row in prior) {
            let size=Int64.parse(row.required(1))
            if(size<1 || size>65536){throw IllegalStateException("document preparation history size changed")}
            let charge=allocate(size)
            try {
                // Framed codec nodes use at least one byte. This conservative
                // bound accounts even corrupt dense data before decoding it.
                charge.ensureDecoded(size,size)
                let selected=transaction.query("SELECT payload FROM audit_events WHERE id=? AND operation_id=? AND kind='plugin_document_payload_prepared' AND length(CAST(payload AS BLOB))=?",
                    [SqlParameter.Text(row.required(0)),SqlParameter.Text(parentOperation.value),SqlParameter.Int64Value(size)])
                if(selected.size!=1){throw IllegalStateException("document preparation history changed")}
                let old=decodeStoredValue(selected[0].required(0))
                if(httpIntentText(old,"parent_item_id")!=parentItem.value || httpIntentText(old,"parent_operation_id")!=parentOperation.value){
                    throw IllegalStateException("document preparation history belongs to another parent")}
                let oldIntent = parsePluginDocumentIntent(old.field("intent").getOrThrow()).value().getOrThrow()
                if (oldIntent.id == intent.id || oldIntent.key == intent.key) {
                    if (selected[0].required(0) != encoded) { throw IllegalStateException("document payload preparation changed") }
                    same++
                }
            }finally{charge.close()}
        }
        if (same > 1 || count > 8 || (same == 0 && count >= 8)) { throw IllegalStateException("document payload preparation history exceeded") }
        if (same == 0) {
            transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "VALUES(?,?,?,'plugin_document_payload_prepared',?,?)", [SqlParameter.Text(httpIntentText(intent.binding(), "thread_id")),
                    SqlParameter.Text(link.runId.value),SqlParameter.Text(parentOperation.value), SqlParameter.Text(encoded), SqlParameter.Int64Value(agentUtcMillis())])
        }
        Result.Ok(())
    } catch (_: Exception) { documentPayloadError("plugin.document_payload_preparation_stale") }
}

func requireDocumentPayloadPlan(transaction: SqliteTransaction, run: RunId,
    parentItem: ItemId, plan: NormalizedOperationPlan,
    allocate: ?(Int64) -> LogicalJsonOwnerReservation, checkCurrent!: Bool = true): Unit {
    let host = plan.canonicalArguments.field("host_plan") ?? nullValue()
    if(httpIntentText(host,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        requireDocumentWindowPayloadPlan(transaction,run,parentItem,plan,allocate,checkCurrent);return}
    if (httpIntentText(host, "version") != PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA) { return }
    if (!isFrozenPluginDocumentParentPlan(plan) || plan.contextReadFacts.size != 1 || allocate.isNone()) {
        throw IllegalStateException("document payload parent requires one actual fact and its allocation owner") }
    if(host.field("result_payload").isSome()){
        requirePreparedPluginDocumentResult(transaction,run,parentItem,plan.canonicalArguments,plan.contextReadFacts[0],allocate.getOrThrow())
    }
    for (raw in host.field("intents").getOrThrow().items) {
        let child = pluginDocumentChildArguments(plan.canonicalArguments, httpIntentText(raw, "id")).value().getOrThrow()
        let intent = parsePluginDocumentIntent(child).value().getOrThrow()
        let fact = requireDocumentPayloadFact(transaction, run, parentItem, plan.contextReadFacts[0], intent)
        if (checkCurrent) { requireDocumentPayloadCurrent(transaction, intent, allocate) }
        if (intent.compareExchange) {
            requireDocumentPayloadMetadata(transaction, intent.nextPayload.getOrThrow())
            let evidence = encodeStoredValue(documentPayloadPreparedEvidence(fact, intent))
            let rows = transaction.query("SELECT id FROM audit_events WHERE thread_id=? AND run_id=? " +
                "AND operation_id=? AND kind='plugin_document_payload_prepared' AND payload=? LIMIT 2", [
                    SqlParameter.Text(httpIntentText(intent.binding(), "thread_id")), SqlParameter.Text(run.value),
                    SqlParameter.Text(documentPayloadParentOperation(fact).value),SqlParameter.Text(evidence)])
            if (rows.size != 1) { throw IllegalStateException("document replacement has no exact Host preparation pin") }
        }
    }
}

func requireDocumentPayloadOperation(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, plan: NormalizedOperationPlan, allocate: ?(Int64) -> LogicalJsonOwnerReservation): Unit {
    if(httpIntentText(plan.canonicalArguments.field("host_plan") ?? nullValue(),"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
        let actual=transaction.query("SELECT tool_call_item_id,normalized_plan FROM operations WHERE id=? AND run_id=?",
            [SqlParameter.Text(operation.value),SqlParameter.Text(run.value)])
        if(actual.size!=1 || actual[0].required(1)!=encodeOperationPlan(plan)){throw IllegalStateException("window parent operation changed")}
        requireDocumentWindowPayloadPlan(transaction,run,ItemId(actual[0].required(0)),plan,allocate,true);return}
    if (httpIntentText(plan.canonicalArguments.field("host_plan") ?? nullValue(), "version") != PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA) { return }
    let rows = transaction.query("SELECT tool_call_item_id,normalized_plan FROM operations WHERE id=? AND run_id=?", [
        SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("document parent operation is absent") }
    if (rows[0].required(1) != encodeOperationPlan(plan)) { throw IllegalStateException("document parent plan changed") }
    requireDocumentPayloadPlan(transaction, run, ItemId(rows[0].required(0)), plan, allocate)
}
