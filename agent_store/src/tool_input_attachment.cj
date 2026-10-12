package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// The existing exact readonly-root proof is reused without an admission,
// budget charge, child Operation, parent grant or new Source constructor.
// The actual Direct source's live validator must run OUTSIDE this transaction.
func requireToolInputAttachmentRoot(tx: SqliteTransaction, operation: OperationId, run: RunId,
    thread: ThreadId, epoch: Int64, source: OperationRootSource, plan: NormalizedOperationPlan): ReadonlyDerivedNode {
    let ancestry = requireReadonlyDerivedAncestors(tx, operation, run, Some(source))
    let node = ancestry.root
    if (ancestry.ancestors.size != 1 || node.operation.value != operation.value || node.parent != "" ||
        node.thread.value != thread.value || node.epoch != epoch || node.state != "executing" ||
        encodeOperationPlan(node.plan) != encodeOperationPlan(plan) ||
        plan.canonicalArguments.field("host_plan").getOrThrow().field("input_attachment").isNone()) {
        throw IllegalStateException("input attachment lost its actual ordinary executing Root")
    }
    node
}

public func verifyToolInputAttachmentExecuting(tx: SqliteTransaction, operation: OperationId, run: RunId,
    thread: ThreadId, epoch: Int64, source: OperationRootSource, plan: NormalizedOperationPlan): Unit {
    let _ = requireToolInputAttachmentRoot(tx, operation, run, thread, epoch, source, plan)
}

public func retainToolInputAttachment(tx: SqliteTransaction, operation: OperationId, run: RunId,
    thread: ThreadId, epoch: Int64, source: OperationRootSource, plan: NormalizedOperationPlan,
    artifact: AgentValue): AgentValue {
    let node = requireToolInputAttachmentRoot(tx, operation, run, thread, epoch, source, plan)
    let host = plan.canonicalArguments.field("host_plan").getOrThrow()
    let profile = host.field("input_attachment").getOrThrow()
    if (!toolInputAttachmentProfileValid(profile)) { throw IllegalStateException("input attachment profile is not frozen") }
    let input = plan.canonicalArguments.field("input").getOrThrow()
    let value = input.field(httpIntentText(profile, "field")).getOrThrow()
    if (value.unifiedKind != ValueKind.Text || value.text.size > readonlyDelegationInteger(profile, "max_bytes") ||
        !httpIntentExactFields(artifact, ["ref", "sha256", "bytes", "content_type"]) ||
        httpIntentText(artifact, "sha256") != modelPolicySha256Text(value.text) ||
        httpIntentText(artifact, "ref") != "blob:sha256:" + modelPolicySha256Text(value.text) ||
        artifact.field("bytes").getOrThrow().unifiedKind != ValueKind.Number ||
        artifact.field("bytes").getOrThrow().asNumberText() != value.text.size.toString() ||
        httpIntentText(artifact, "content_type") != "text/plain; charset=utf-8") {
        throw IllegalStateException("input artifact differs from the complete actual canonical text")
    }
    let hash = httpIntentText(artifact, "sha256")
    let metadata = tx.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(hash)])
    if (metadata.size != 1 || metadata[0].required(0) != "text/plain; charset=utf-8" ||
        metadata[0].required(1) != value.text.size.toString() || metadata[0].required(3) != "blobs/" + hash + ".txt") {
        throw IllegalStateException("input artifact has no exact durable metadata")
    }
    let recorded = parseUnifiedJson(metadata[0].required(2), maxBytes: 4096, maxDepth: 4)
    if (!httpIntentExactFields(recorded, ["version", "ref", "sha256", "bytes", "content_type"]) ||
        recorded.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        recorded.field("version").getOrThrow().asNumberText() != "1") {
        throw IllegalStateException("input artifact metadata changed")
    }
    for (field in artifact.fields) {
        if (canonicalAgentValue(recorded.field(field.name).getOrThrow()) != canonicalAgentValue(field.value)) {
            throw IllegalStateException("input artifact metadata differs from the actual file")
        }
    }
    let reserved = tx.query("SELECT reserved_receipt_id FROM operation_effect_records WHERE operation_id=? AND run_id=? " +
        "AND tool_call_item_id=? AND normalized_plan=?", [SqlParameter.Text(operation.value), SqlParameter.Text(run.value),
        SqlParameter.Text(node.item.value), SqlParameter.Text(encodeOperationPlan(plan))])
    if (reserved.size != 1 || reserved[0].required(0) == "") {
        throw IllegalStateException("input attachment has no original reserved Receipt identity")
    }
    let evidence = objectValue([ValueField("schema", textValue(TOOL_INPUT_ATTACHMENT_SCHEMA)),
        ValueField("profile", profile), ValueField("artifact", artifact), ValueField("thread_id", textValue(thread.value)),
        ValueField("run_id", textValue(run.value)), ValueField("epoch", integerValue(epoch)),
        ValueField("operation_id", textValue(operation.value)), ValueField("call_id", textValue(node.callId)),
        ValueField("namespace", host.field("plugin").getOrThrow()), ValueField("package_digest", host.field("package_digest").getOrThrow()),
        ValueField("generation", host.field("generation").getOrThrow()),
        ValueField("configuration_digest", host.field("configuration_digest").getOrThrow()),
        ValueField("reserved_receipt_id", textValue(reserved[0].required(0)))])
    if (!toolInputAttachmentEvidenceValid(evidence)) { throw IllegalStateException("input attachment evidence exceeds its exact shape") }
    let original = tx.query("SELECT payload,provenance FROM items WHERE id=?", [SqlParameter.Text(node.item.value)])
    if (original.size != 1 || original[0].required(0).size > 8388608 || original[0].required(1).size > 8192) {
        throw IllegalStateException("input attachment original call exceeds its existing durable bound") }
    let stored = encodeStoredValue(objectValue([ValueField("evidence", evidence),
        ValueField("call_payload", textValue(original[0].required(0))),
        ValueField("call_provenance", textValue(original[0].required(1)))]))
    let prior = tx.query("SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind='tool_input_attached'",
        [SqlParameter.Text(operation.value)])
    if (prior.size > 1 || (prior.size == 1 && (prior[0].required(0) != thread.value ||
        prior[0].required(1) != run.value || prior[0].required(2) != stored))) {
        throw IllegalStateException("this Root already retained different input evidence")
    }
    if (prior.isEmpty()) {
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
            "VALUES(?,?,?,'tool_input_attached',?,?)", [SqlParameter.Text(thread.value), SqlParameter.Text(run.value),
            SqlParameter.Text(operation.value), SqlParameter.Text(stored), SqlParameter.Int64Value(agentUtcMillis())])
    }
    evidence
}
