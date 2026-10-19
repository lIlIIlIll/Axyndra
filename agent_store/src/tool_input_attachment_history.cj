package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Historical descriptive data only. This method creates no live Source,
// admission, owner, grant or Root. Its caller already selected the actual Run.
public func completedToolInputAttachmentEvidence(tx: SqliteTransaction, operation: OperationId,
    run: RunId): ?AgentValue {
    try {
        let rows = tx.query("SELECT r.thread_id,r.turn_id,r.epoch,o.normalized_plan,call.id,call.payload,call.provenance," +
            "receipt.id,receipt.detail,result.payload,result.provenance,a.payload,handoff.payload " +
            "FROM operations o JOIN runs r ON r.id=o.run_id " +
            "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=r.id AND e.normalized_plan=o.normalized_plan AND e.tool_call_item_id=o.tool_call_item_id " +
            "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
            "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id AND call.kind='tool_call' " +
            "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
            "JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id AND result.turn_id=r.turn_id AND result.kind='tool_result' " +
            "JOIN audit_events a ON a.operation_id=o.id AND a.run_id=r.id AND a.thread_id=r.thread_id AND a.kind='tool_input_attached' " +
            "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=r.id AND handoff.thread_id=r.thread_id AND handoff.kind='operation_execution_handoff' " +
            "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND receipt.outcome='completed' " +
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions d WHERE d.operation_id=o.id)",
            [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
        if (rows.size != 1) { return None }
        let row = rows[0]
        let plan = decodeOperationPlan(row.required(3))
        if (!isFrozenReadonlyDelegationParentPlan(plan)) { return None }
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        let pin = decodeStoredValue(row.required(11))
        if (!httpIntentExactFields(pin, ["evidence", "call_payload", "call_provenance"]) ||
            httpIntentText(pin, "call_payload") != row.required(5) ||
            httpIntentText(pin, "call_provenance") != row.required(6)) { return None }
        let evidence = pin.field("evidence").getOrThrow()
        if (!toolInputAttachmentEvidenceValid(evidence) ||
            httpIntentText(evidence, "thread_id") != row.required(0) || httpIntentText(evidence, "run_id") != run.value ||
            httpIntentText(evidence, "operation_id") != operation.value || httpIntentText(evidence, "reserved_receipt_id") != row.required(7) ||
            readonlyDelegationInteger(evidence, "epoch").toString() != row.required(2) ||
            canonicalAgentValue(evidence.field("profile").getOrThrow()) != canonicalAgentValue(host.field("input_attachment").getOrThrow()) ||
            httpIntentText(evidence, "namespace") != httpIntentText(host, "plugin") ||
            httpIntentText(evidence, "package_digest") != httpIntentText(host, "package_digest") ||
            httpIntentText(evidence, "generation") != httpIntentText(host, "generation") ||
            httpIntentText(evidence, "configuration_digest") != httpIntentText(host, "configuration_digest") ||
            row.required(12) != encodeStoredValue(readonlyDerivedParentHandoff(plan, Int64.parse(row.required(2))))) { return None }
        let provenance = decodeStoredProvenance(row.required(6))
        let resultProvenance = decodeStoredProvenance(row.required(10))
        if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
            resultProvenance.runId.isNone() || resultProvenance.runId.getOrThrow().value != run.value ||
            resultProvenance.operationId.isNone() || resultProvenance.operationId.getOrThrow().value != operation.value) { return None }
        let callId = match (decodeStoredThreadContent(row.required(5))) {
            case ThreadItemContent.ToolCall(id, name, _) => if (name != plan.toolName) { return None } else { id.value }
            case _ => return None }
        if (httpIntentText(evidence, "call_id") != callId) { return None }
        let decisions = tx.query("SELECT d.id,b.scoped_tool_call_id FROM decision_operations source " +
            "JOIN model_decisions d ON d.id=source.decision_id JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
            "JOIN model_decision_blocks b ON b.decision_id=d.id AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
            "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
            "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? AND b.kind='tool_call' " +
            "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
            [SqlParameter.Text(operation.value), SqlParameter.Text(row.required(4)), SqlParameter.Text(run.value)])
        if (provenance.source == "direct_tool") {
            if (provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operation.value || !decisions.isEmpty() ||
                !tx.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?", [SqlParameter.Text(row.required(4))]).isEmpty()) { return None }
        } else if (decisions.size != 1 || provenance.operationId.isSome()) { return None }
        match (decodeStoredThreadContent(row.required(9))) {
            case ThreadItemContent.ToolResult(id, op, receipt, output, isError) =>
                if (id.value != callId || op.value != operation.value || receipt != row.required(7) ||
                    canonicalAgentValue(output) != canonicalAgentValue(decodeStoredValue(row.required(8)))) { return None }
            case _ => return None }
        let artifact = evidence.field("artifact").getOrThrow()
        let source = plan.canonicalArguments.field("input").getOrThrow().field(httpIntentText(evidence.field("profile").getOrThrow(), "field")).getOrThrow()
        if (source.unifiedKind != ValueKind.Text || source.text.size != readonlyDelegationInteger(artifact, "bytes") ||
            modelPolicySha256Text(source.text) != httpIntentText(artifact, "sha256")) { return None }
        let metadata = tx.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(httpIntentText(artifact, "sha256"))])
        if (metadata.size != 1 || metadata[0].required(0) != httpIntentText(artifact, "content_type") ||
            metadata[0].required(1) != source.text.size.toString() || metadata[0].required(3) != "blobs/" + httpIntentText(artifact, "sha256") + ".txt") { return None }
        let stored = parseUnifiedJson(metadata[0].required(2), maxBytes: 4096, maxDepth: 4)
        if (!httpIntentExactFields(stored, ["version", "ref", "sha256", "bytes", "content_type"]) ||
            stored.field("version").getOrThrow().unifiedKind != ValueKind.Number || stored.field("version").getOrThrow().asNumberText() != "1") { return None }
        for (field in artifact.fields where canonicalAgentValue(field.value) != canonicalAgentValue(stored.field(field.name).getOrThrow())) { return None }
        Some(evidence)
    } catch (_: Exception) { None }
}
