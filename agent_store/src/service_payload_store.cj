package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// This check runs inside the SAME transaction as canonical operation changes.
// An artifacts row only proves registered content metadata. The exact staged
// witness binds that content to this live preparation and canonical call; it
// never replaces the existing source, approval, startup or ParentIntent proof.
func requireServicePayloadPlan(transaction: SqliteTransaction, runId: RunId,
    itemId: ItemId, plan: NormalizedOperationPlan): Unit {
    let channel = isFrozenChannelParentPlan(plan); let http = isFrozenHttpStreamParentPlan(plan)
    if (!channel && !http) { return }
    let host = plan.canonicalArguments.field("host_plan").getOrThrow()
    let version = httpIntentText(host, "version")
    if (version != HOST_CHANNEL_PAYLOAD_INTENT_VERSION && version != HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION) { return }
    let binding = host.field("binding").getOrThrow()
    let limits = servicePayloadLimits(binding).value().getOrThrow().getOrThrow()
    let rows = transaction.query("SELECT r.thread_id,r.epoch,i.payload FROM runs r JOIN items i ON i.id=? " +
        "AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id WHERE r.id=? AND i.kind='tool_call'",
        [SqlParameter.Text(itemId.value), SqlParameter.Text(runId.value)])
    channelStoreRequire(rows.size == 1)
    let row = rows[0]
    let callId = match (decodeStoredThreadContent(row.required(2))) {
        case ThreadItemContent.ToolCall(id, name, _) => channelStoreRequire(name == plan.toolName); id.value
        case _ => throw IllegalStateException("artifact plan lacks its canonical ToolCall")
    }
    for (intent in host.field("intents").getOrThrow().items) {
        let selected = if (http) { intent.field("request").getOrThrow().field("body_payload") } else { intent.field("payload") }
        // The only unreferenced v2 HTTP body is an empty request, validated above.
        if (selected.isNone()) { continue }
        let payload = selected.getOrThrow()
        let witnessIntent = if (http) { objectValue([ValueField("id", intent.field("id").getOrThrow()), ValueField("payload", payload)]) } else { intent }
        let size = servicePayloadReferenceBytes(payload, limits.maxWriteBytes).value().getOrThrow()
        requireServicePayloadMetadata(transaction, payload, size)
        let witness = servicePayloadPreparationWitness(row.required(0), runId.value, Int64.parse(row.required(1)),
            callId, plan.toolName, plan.canonicalArguments.field("input").getOrThrow(), binding, witnessIntent)
        let audits = transaction.query("SELECT id FROM audit_events WHERE kind='service_payload_prepared' " +
            "AND thread_id=? AND run_id=? AND operation_id IS NULL AND payload=?",
            [SqlParameter.Text(row.required(0)), SqlParameter.Text(runId.value), SqlParameter.Text(encodeStoredValue(witness))])
        channelStoreRequire(audits.size == 1)
    }
}

func requireServicePayloadMetadata(transaction: SqliteTransaction, payload: AgentValue, rawBytes: Int64): Unit {
    let digest = httpIntentText(payload, "encoded_sha256")
    let rows = transaction.query("SELECT mime,size,relative_path,metadata FROM artifacts WHERE hash=?", [SqlParameter.Text(digest)])
    channelStoreRequire(rows.size == 1 && rows[0].required(0) == "text/plain; charset=utf-8" &&
        rows[0].required(1) == (rawBytes * 2).toString() && rows[0].required(2) == "blobs/" + digest + ".txt")
    let metadata = parseUnifiedJson(rows[0].required(3), maxBytes: 4096, maxDepth: 4)
    channelStoreRequire(httpIntentExactFields(metadata, ["version", "ref", "sha256", "bytes", "content_type"]) &&
        metadata.field("version").getOrThrow().unifiedKind == ValueKind.Number && metadata.field("version").getOrThrow().asNumberText() == "1" &&
        httpIntentText(metadata, "ref") == "blob:sha256:" + digest && httpIntentText(metadata, "sha256") == digest &&
        metadata.field("bytes").getOrThrow().unifiedKind == ValueKind.Number && metadata.field("bytes").getOrThrow().asNumberText() == (rawBytes * 2).toString() &&
        httpIntentText(metadata, "content_type") == "text/plain; charset=utf-8")
}
