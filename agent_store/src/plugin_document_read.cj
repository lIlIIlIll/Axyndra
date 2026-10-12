package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func requirePluginDocumentLane(transaction: SqliteTransaction, thread: ThreadId, run: RunId, epoch: Int64): LaneId {
    let rows = transaction.query("SELECT b.lane_id FROM run_lane_bindings b " +
        "JOIN runs r ON r.id=b.run_id AND r.thread_id=b.thread_id " +
        "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "JOIN lanes lane ON lane.thread_id=b.thread_id AND lane.lane_id=b.lane_id " +
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND r.state='running' AND r.finished_at_millis IS NULL " +
        "AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' AND lane.status='open'",
        [SqlParameter.Text(run.value), SqlParameter.Text(thread.value), SqlParameter.Int64Value(epoch)])
    if (rows.size != 1) { throw IllegalStateException("document read has no unique current canonical lane") }
    LaneId(rows[0].required(0))
}

// Called only after the same transaction has checked the exact executing
// ContextRead Operation, complete plan, origin, state register and handoff.
func requirePluginDocumentReadScope(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): LaneId {
    let request = plan.canonicalArguments
    if (!pluginDocumentReadAuthority(plan)) { throw IllegalStateException("invalid document read authority") }
    let binding = request.field("binding").getOrThrow()
    let origin = match (source.origin) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("document read is not a ContextRead") }
    let lane = requirePluginDocumentLane(transaction, source.threadId, source.runId, source.epoch)
    if (httpIntentText(binding, "thread_id") != source.threadId.value || httpIntentText(binding, "run_id") != source.runId.value ||
        binding.field("epoch").getOrThrow().asNumberText() != source.epoch.toString() ||
        httpIntentText(binding, "lane_id") != lane.value || origin.parentCallItemId == "" ||
        origin.ownerNamespace != httpIntentText(binding, "namespace") || origin.packageDigest != httpIntentText(binding, "package_digest") ||
        origin.configurationDigest != httpIntentText(binding, "configuration_digest") ||
        origin.projectionDigest != httpIntentText(request, "projection_digest")) {
        throw IllegalStateException("document read has another canonical scope") }
    let parents = transaction.query("SELECT item.payload FROM items item JOIN item_tree_edges edge ON edge.item_id=item.id " +
        "AND edge.thread_id=item.thread_id WHERE item.id=? AND item.thread_id=? AND item.turn_id=? AND edge.lane_id=? " +
        "AND item.kind='tool_call' AND NOT EXISTS(SELECT 1 FROM operations o WHERE o.tool_call_item_id=item.id)",
        [SqlParameter.Text(origin.parentCallItemId), SqlParameter.Text(source.threadId.value),
            SqlParameter.Text(source.turnId.value), SqlParameter.Text(lane.value)])
    if (parents.size != 1) { throw IllegalStateException("document read lost its unprepared canonical parent") }
    match (decodeStoredThreadContent(parents[0].required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) => if (id.value != httpIntentText(binding, "parent_call_id") ||
            name != httpIntentText(binding, "contribution")) { throw IllegalStateException("document read parent differs from its frozen binding") }
        case _ => throw IllegalStateException("document parent is not a ToolCall") }
    lane
}

func readPluginDocumentsInTransaction(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan, materializer!: ?PluginDocumentPayloadMaterializer = None): AgentValue {
    let lane = if(pluginDocumentContextReadRequestValid(plan.canonicalArguments)){
        requirePluginDocumentContextReadScope(transaction,source,plan)
    }else{requirePluginDocumentReadScope(transaction,source,plan)}
    let request = plan.canonicalArguments
    let origin = match (source.origin) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("document read is not a ContextRead") }
    let referenced = httpIntentText(request, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA
    if (referenced != materializer.isSome()) { throw IllegalStateException("document payload read requires its actual materializer") }
    let documents = ArrayList<AgentValue>()
    var rawBytes: Int64 = 0
    for (key in request.field("keys").getOrThrow().items) {
        // Bound length before selecting payload. No data is exposed through a
        // metadata-only preflight; the actual read is here after handoff.
        let lengths = queryPluginDocumentRows(transaction,"SELECT length(CAST(payload AS BLOB)),revision FROM plugin_documents " +
            "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
            [SqlParameter.Text(source.threadId.value), SqlParameter.Text(lane.value),
                SqlParameter.Text(origin.ownerNamespace), SqlParameter.Text(key.text)])
        if (!lengths.isEmpty()) {
            let count = Int64.parse(lengths[0].required(0))
            if (count < 0 || count > (if (referenced) { PLUGIN_DOCUMENT_MAX_BYTES } else { RUN_CONTEXT_SNAPSHOT_MAX_BYTES - rawBytes })) {
                throw IllegalStateException("document read exceeds canonical context fact capacity") }
            rawBytes += count
        }
        if (referenced) {
            let count = if (lengths.isEmpty()) { 4 } else { Int64.parse(lengths[0].required(0)) }
            let revision = if (lengths.isEmpty()) { 0 } else { Int64.parse(lengths[0].required(1)) }
            if (lengths.size > 1 || revision < 0 || (!lengths.isEmpty() && revision == 0)) {
                throw IllegalStateException("document payload read encountered corrupt metadata") }
            let proof = SqlitePluginDocumentPayloadReadProof(transaction, source, plan, lane, key.text, revision, count)
            let result = try { materializer.getOrThrow().materialize(proof) } finally { proof.close() }
            let payload = match (result) { case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(value) => value }
            if (!proof.verifiedResult(payload)) { throw IllegalStateException("materializer returned an unverified reference") }
            documents.add(objectValue([ValueField("key", textValue(key.text)), ValueField("revision", integerValue(revision)),
                ValueField("payload", payload)]))
            continue
        }
        let rows = queryPluginDocumentRows(transaction,"SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
            [SqlParameter.Text(source.threadId.value), SqlParameter.Text(lane.value),
                SqlParameter.Text(origin.ownerNamespace), SqlParameter.Text(key.text)])
        let revision = if (rows.isEmpty()) { 0 } else { Int64.parse(rows[0].required(0)) }
        let raw = if (rows.isEmpty()) { "null" } else { rows[0].required(1) }
        if (rows.size > 1 || revision < 0 || (!rows.isEmpty() && revision == 0)) {
            throw IllegalStateException("document read encountered corrupt metadata") }
        match(transaction.documentStorageBackend(origin.ownerNamespace,key.text)){
            case Some(backend)=>backend.recordRead(transaction,source,plan,
                PluginDocumentSnapshot(source.threadId,lane,origin.ownerNamespace,key.text,revision,raw));case None=>()}
        documents.add(objectValue([ValueField("key", textValue(key.text)), ValueField("revision", integerValue(revision)),
            ValueField("json", textValue(raw)), ValueField("sha256", textValue(modelPolicySha256Text(raw)))]))
    }
    let value = objectValue([ValueField("schema", textValue(if (referenced) {
            PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA } else { PLUGIN_DOCUMENT_READ_RESULT_SCHEMA })),
        ValueField("request_digest", textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
        ValueField("documents", listValue(documents.toArray()))])
    if (stringifyUnifiedJson(value).size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES || encodeStoredValue(value).size > 8388608) {
        throw IllegalStateException("document read complete fact exceeds durable capacity") }
    value
}
