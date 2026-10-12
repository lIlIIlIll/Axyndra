package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

func requireChannelArtifactObservation(transaction: SqliteTransaction, operationId: OperationId, evidence: AgentValue): Unit {
    channelStoreRequire(httpIntentExactFields(evidence, ["schema", "stream", "artifact", "operation_id"]) &&
        httpIntentText(evidence, "schema") == "axyndra.service-artifact-observation/v1" &&
        httpIntentText(evidence, "operation_id") == operationId.value)
    let stream = httpIntentText(evidence, "stream")
    channelStoreRequire(stream != "" && stream.size <= 32)
    for (byte in stream.toArray()) {
        channelStoreRequire((byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9') || byte == b'_')
    }
    let artifact = evidence.field("artifact").getOrThrow()
    channelStoreRequire(httpIntentExactFields(artifact, ["ref", "sha256", "bytes", "content_type"]))
    let hash = httpIntentText(artifact, "sha256")
    channelStoreRequire(hash.size == 64)
    for (byte in hash.toArray()) { channelStoreRequire((byte >= b'a' && byte <= b'f') || (byte >= b'0' && byte <= b'9')) }
    let count = artifact.field("bytes").getOrThrow()
    channelStoreRequire(count.unifiedKind == ValueKind.Number)
    let size = Int64.parse(count.asNumberText())
    channelStoreRequire(size >= 0 && size <= 16777216 && size.toString() == count.asNumberText() &&
        httpIntentText(artifact, "ref") == "blob:sha256:" + hash &&
        httpIntentText(artifact, "content_type") == "text/plain; charset=utf-8")
    let rows = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(hash)])
    channelStoreRequire(rows.size == 1 && rows[0].required(0) == "text/plain; charset=utf-8" &&
        rows[0].required(1) == size.toString() && rows[0].required(3) == "blobs/" + hash + ".txt")
    let metadata = parseUnifiedJson(rows[0].required(2), maxBytes: 4096, maxDepth: 4)
    channelStoreRequire(httpIntentExactFields(metadata, ["version", "ref", "sha256", "bytes", "content_type"]) &&
        metadata.field("version").getOrThrow().unifiedKind == ValueKind.Number &&
        metadata.field("version").getOrThrow().asNumberText() == "1")
    for (field in artifact.fields) {
        channelStoreRequire(canonicalAgentValue(metadata.field(field.name).getOrThrow()) == canonicalAgentValue(field.value))
    }
}
