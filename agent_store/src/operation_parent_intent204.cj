package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// One original canonical ParentIntent validator, shared by Operation and plan
// admission inside the caller's existing transaction. Allocation is DATA-only;
// source, epoch, exact intent, family, grant and handoff facts remain canonical.
func isSupportedDerivedPair(
    transaction: SqliteTransaction,
    parent: NormalizedOperationPlan,
    parentToolName: String,
    parentCallId: String,
    requestKey: String,
    child: NormalizedOperationPlan
): Bool {
    if (child.toolName == HOST_PLUGIN_CHILD_TOOL111) {
        return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
            isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
            pluginChildParentAllows111(parent, child)
    }
    if(child.toolName==HOST_PLUGIN_DOCUMENT_TOOL && isPluginDocumentRowJournalChildPlan(child)){
        return parent.toolName==parentToolName && isJavaScriptPluginName(parentToolName) &&
            isSupportedDerivedChildPlan(parentToolName,parentCallId,requestKey,child) && pluginDocumentRowJournalParentAllows(parent,child)
    }
    if (child.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
        return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
            isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
            pluginDocumentParentAllows(parent, child)
    }
    if (child.toolName == "host.file.plan.propose" &&
        (isFrozenChannelParentPlan(parent) || child.canonicalArguments.field("managed_binding").isSome())) {
        if (!isFrozenChannelParentPlan(parent) ||
            !isSupportedDerivedParentPlan(parent, parentToolName) ||
            !isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) ||
            !httpIntentExactFields(child.canonicalArguments, ["plugin", "generation", "package_digest", "proposal", "managed_binding"])) {
            return false
        }
        let binding = parent.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        if (canonicalAgentValue(child.canonicalArguments.field("managed_binding").getOrThrow()) != canonicalAgentValue(binding) ||
            httpIntentText(child.canonicalArguments, "plugin") != httpIntentText(binding, "plugin") ||
            httpIntentText(child.canonicalArguments, "package_digest") != httpIntentText(binding, "package_digest")) { return false }
        requireChannelStartupReceipt(transaction, binding, parent)
        return true
    }
    if (child.toolName == HOST_HTTP_SERVICE_TOOL || child.toolName == HOST_CHANNEL_WRITE_TOOL || child.toolName == HOST_HTTP_STREAM_TOOL || (child.toolName == HOST_READ_VIEW_TOOL || child.toolName == HOST_PLUGIN_DOCUMENT_TOOL)) {
        return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
            isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
            exactServiceChildAllowed(parent, child)
    }
    isSupportedDerivedParentPlan(parent, parentToolName) &&
        isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child)
}

func isSupportedDerivedParentPlan(
    plan: NormalizedOperationPlan,
    toolName: String
): Bool {
    if (toolName == "run_program") { return plan.toolName == "run_program" }
    plan.toolName == toolName && isJavaScriptPluginName(toolName) &&
        operationPlanRequiresCapability(plan, CapabilityKind.ExtensionInvoke) &&
        operationPlanRequiresCapability(plan, CapabilityKind.WorkspaceRead)
}

func isSupportedDerivedChildPlan(
    parentToolName: String,
    parentCallId: String,
    requestKey: String,
    plan: NormalizedOperationPlan
): Bool {
    if (parentToolName == "run_program") {
        return plan.toolName != "run_program" && !isPluginOnlyServiceName(plan.toolName) &&
            plan.effectClass == OperationEffectClass.ReadOnly
    }
    if (!isJavaScriptPluginName(parentToolName)) { return false }
    let requestPrefix = "javascript-service:" + parentCallId + ":"
    if (plan.toolName == HOST_PLUGIN_CHILD_TOOL111 || plan.toolName == HOST_HTTP_SERVICE_TOOL || plan.toolName == HOST_CHANNEL_WRITE_TOOL || plan.toolName == HOST_HTTP_STREAM_TOOL || (plan.toolName == HOST_READ_VIEW_TOOL || plan.toolName == HOST_PLUGIN_DOCUMENT_TOOL)) {
        if (!isExactServiceChildPlan(plan)) { return false }
        // A transport ID cannot mint a second execution of one intent.
        return requestKey == exactServiceRequestKey(parentCallId, plan)
    }
    requestKey.startsWith(requestPrefix) && requestKey.size > requestPrefix.size &&
        isPluginServiceChildPlan(plan)
}

func isPluginServiceChildPlan(plan: NormalizedOperationPlan): Bool {
    if ((plan.toolName != "bash_readonly" && !isPluginOnlyServiceName(plan.toolName)) ||
        plan.effectClass != OperationEffectClass.ReadOnly ||
        plan.networkPolicy.mode != NetworkPolicyMode.Denied) {
        return false
    }
    for (required in plan.requiredCapabilities) {
        if (required.kind != CapabilityKind.WorkspaceRead) { return false }
    }
    true
}

func isPluginOnlyServiceName(name: String): Bool {
    name == HOST_PLUGIN_CHILD_TOOL111 || name == "host.process.readonly" || name == "host.file.plan.propose" ||
        name == HOST_HTTP_SERVICE_TOOL || name == HOST_CHANNEL_WRITE_TOOL || name == HOST_HTTP_STREAM_TOOL || (name == HOST_READ_VIEW_TOOL || name == HOST_PLUGIN_DOCUMENT_TOOL)
}

func isJavaScriptPluginName(toolName: String): Bool {
    toolName.startsWith("plugin.") && toolName.size > 7
}

func operationPlanRequiresCapability(
    plan: NormalizedOperationPlan,
    kind: CapabilityKind
): Bool {
    for (required in plan.requiredCapabilities) {
        if (required.kind == kind) { return true }
    }
    false
}

func isFrozenHttpParentPlan(plan: NormalizedOperationPlan): Bool {
    if (!httpIntentExactFields(plan.canonicalArguments, ["input", "configuration", "host_plan"])) {
        return false
    }
    let host = plan.canonicalArguments.field("host_plan").getOrThrow()
    if (!httpIntentExactFields(host,
        ["version", "plugin", "package_digest", "generation", "configuration_digest", "intents"]) ||
        httpIntentText(host, "version") != HOST_HTTP_INTENT_VERSION) { return false }
    let namespace = httpIntentText(host, "plugin")
    httpServicePluginNamespace(namespace) &&
        httpServicePackageDigest(httpIntentText(host, "package_digest")) &&
        plan.toolName.startsWith("plugin." + namespace + ".") &&
        plan.implementation.implementationFingerprint == namespace + ":" + httpIntentText(host, "package_digest")
}

func isFrozenExactParentPlan(plan: NormalizedOperationPlan): Bool {
    isFrozenHttpParentPlan(plan) || isFrozenChannelParentPlan(plan) || isFrozenHttpStreamParentPlan(plan) ||
        isFrozenReadViewParentPlan(plan) || isFrozenReadonlyDelegationParentPlan(plan) || isFrozenPluginDocumentParentPlan(plan) ||
        isFrozenPluginChildParent111(plan)
}

func exactParentHandoffEvidence(plan: NormalizedOperationPlan, epoch: String): AgentValue {
    if (isFrozenReadonlyDelegationParentPlan(plan)) { return readonlyDerivedParentHandoff(plan, Int64.parse(epoch)) }
    if (isFrozenPluginChildParent111(plan)) { return objectValue([
        ValueField("child_parent_epoch", textValue(epoch)),
        ValueField("parent_plan_digest", textValue(modelPolicySha256Text(encodeOperationPlan(plan))))]) }
    objectValue([
        ValueField(if (isFrozenPluginDocumentParentPlan(plan)) { "document_parent_epoch" } else if (isFrozenReadViewParentPlan(plan)) { "read_view_parent_epoch" } else if (isFrozenChannelParentPlan(plan)) { "channel_parent_epoch" } else if (isFrozenHttpStreamParentPlan(plan)) { "http_stream_parent_epoch" } else { "http_parent_epoch" }, textValue(epoch)),
        ValueField("parent_plan_digest", textValue(if (isFrozenPluginDocumentParentPlan(plan)) { modelPolicySha256Text(encodeOperationPlan(plan)) } else { plan.bindingDigest }))
    ])
}

// ParentIntent is a separate durable authorization source, never a User
// approval. Reconstruct it from canonical facts inside the same transaction
// as admission/execution/handoff; an API caller cannot supply the proof.
func exactParentIntentEvidenceInTransaction204(
    transaction: SqliteTransaction,
    operationId: OperationId,
    runId: RunId,
    childPlan: NormalizedOperationPlan,
    allowCancellingSettlement!: Bool = false,
    completedDocumentChild!: Bool = false,
    documentPayloadAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None
): AgentValue {
    if (completedDocumentChild) {
        // This private branch validates a result already committed by the
        // same child. It never permits admission or a new execution.
        let window=isPluginDocumentRowJournalChildPlan(childPlan)
        let result=if(window){parsePluginDocumentRowJournalIntent(childPlan.canonicalArguments).value().getOrThrow().result()}
            else{parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().result()}
        let referenced=window || parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().referencesPayload
        if (allowCancellingSettlement || childPlan.toolName != HOST_PLUGIN_DOCUMENT_TOOL || !referenced) {
            throw IllegalStateException("completed document result requires its exact payload child") }
        let completed = transaction.query("SELECT receipt.id FROM operations child " +
            "JOIN operation_effect_records effect ON effect.operation_id=child.id AND effect.run_id=child.run_id " +
            "AND effect.tool_call_item_id=child.tool_call_item_id AND effect.normalized_plan=child.normalized_plan " +
            "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state='committed' " +
            "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=effect.reserved_receipt_id " +
            "WHERE child.id=? AND child.run_id=? AND child.state='committed' AND child.normalized_plan=? " +
            "AND receipt.outcome='completed' AND receipt.detail=? LIMIT 2",
            [SqlParameter.Text(operationId.value),SqlParameter.Text(runId.value),SqlParameter.Text(encodeOperationPlan(childPlan)),
                SqlParameter.Text(encodeStoredValue(result))])
        if (completed.size != 1) { throw IllegalStateException("completed document result has no exact committed child receipt") }
    }
    let readOnlyProposal = childPlan.toolName == "host.file.plan.propose" &&
        childPlan.canonicalArguments.field("managed_binding").isSome() && isPluginServiceChildPlan(childPlan)
    if (!isExactServiceChildPlan(childPlan) && !readOnlyProposal) {
        throw IllegalStateException("service child does not have a bounded frozen intent or read-only managed proposal")
    }
    let rows = transaction.query(
        "SELECT parent.id,parent.normalized_plan,parent.tool_call_item_id,runs.thread_id," +
            "runs.turn_id,runs.epoch,items.payload,items.provenance,a.request_key,handoff.id,handoff.payload " +
            "FROM operations child JOIN derived_operation_admissions a ON a.operation_id=child.id " +
            "JOIN operations parent ON parent.id=a.parent_operation_id " +
            "JOIN runs ON runs.id=parent.run_id JOIN threads ON threads.id=runs.thread_id " +
            "JOIN items ON items.id=parent.tool_call_item_id " +
            "JOIN operation_effect_records pe ON pe.operation_id=parent.id " +
            "JOIN operation_state_registers ps ON ps.operation_id=parent.id " +
            "JOIN operation_effect_records ce ON ce.operation_id=child.id " +
            "JOIN operation_state_registers cs ON cs.operation_id=child.id " +
            "JOIN audit_events handoff ON handoff.operation_id=parent.id " +
            " AND handoff.run_id=runs.id AND handoff.thread_id=runs.thread_id " +
            " AND handoff.kind='operation_execution_handoff' " +
            "WHERE child.id=? AND child.run_id=? AND parent.run_id=child.run_id " +
            "AND child.tool_call_item_id=parent.tool_call_item_id " +
            "AND runs.state IN (" + (if (allowCancellingSettlement) { "'running','cancelling'" }
                else { "'running'" }) + ") AND threads.active_turn_id=runs.turn_id " +
            "AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
            "AND items.kind='tool_call' AND parent.state='executing' AND ps.state='executing' " +
            "AND pe.run_id=runs.id AND pe.tool_call_item_id=items.id " +
            "AND pe.normalized_plan=parent.normalized_plan " +
            "AND ce.run_id=runs.id AND ce.tool_call_item_id=items.id " +
            "AND ce.normalized_plan=child.normalized_plan AND cs.state=child.state " +
            "AND child.normalized_plan=? AND a.request_digest=? " +
            "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions nested " +
            "WHERE nested.operation_id=parent.id)",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
            SqlParameter.Text(encodeOperationPlan(childPlan)), SqlParameter.Text(childPlan.bindingDigest)]
    )
    if (rows.size != 1) {
        throw IllegalStateException("service ParentIntent has no unique active canonical parent handoff")
    }
    let row = rows[0]
    let parentId = row.required(0)
    let parentPlan = decodeOperationPlan(row.required(1))
    requireServicePayloadPlan(transaction, runId, ItemId(row.required(2)), parentPlan)
    if (!allowCancellingSettlement) { requireDocumentPayloadPlan(transaction, runId, ItemId(row.required(2)),
        parentPlan, documentPayloadAllocation, checkCurrent: false) }
    let handoffEvidence = exactParentHandoffEvidence(parentPlan, row.required(5))
    if (!isFrozenExactParentPlan(parentPlan) || row.required(10) != encodeStoredValue(handoffEvidence)) {
        throw IllegalStateException("service parent handoff belongs to another epoch or frozen plan")
    }
    if (childPlan.toolName == HOST_CHANNEL_WRITE_TOOL || childPlan.toolName == HOST_HTTP_STREAM_TOOL || readOnlyProposal) {
        let binding = childPlan.canonicalArguments.field(if (readOnlyProposal) { "managed_binding" } else { "binding" }).getOrThrow()
        if (httpIntentText(binding, "target_thread_id") != managedJobServiceThread(transaction,
            ItemId(row.required(2)), row.required(3), runId, binding)) {
            throw IllegalStateException("channel parent belongs to another target Thread")
        }
        if (childPlan.toolName == HOST_CHANNEL_WRITE_TOOL || readOnlyProposal) { requireChannelStartupReceipt(transaction, binding, parentPlan) }
        else { requireHttpStreamStartupReceipt(transaction, binding, parentPlan) }
    }
    if (childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
        if(!allowCancellingSettlement || completedDocumentChild){
            match(currentFrozenDocumentResult(parentPlan.canonicalArguments.field("host_plan").getOrThrow(),agentUtcMillis())){
                case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}}
        requirePluginDocumentScope(transaction, OperationId(parentId), runId, row.required(3), row.required(5),
            row.required(2), childPlan, allowCancellingSettlement || completedDocumentChild, documentPayloadAllocation)
        if (completedDocumentChild) { requireCompletedDocumentPayload(transaction, childPlan, documentPayloadAllocation) }
    }
    if (childPlan.toolName == HOST_PLUGIN_CHILD_TOOL111) {
        requirePluginChildScope111(transaction, runId, row.required(3), row.required(5), row.required(2), childPlan)
    }
    let callId = match (decodeStoredThreadContent(row.required(6))) {
        case ThreadItemContent.ToolCall(id, name, _) =>
            if (!isSupportedDerivedPair(transaction, parentPlan, name, id.value, row.required(8), childPlan)) {
                throw IllegalStateException("service child differs from its parent's exact frozen intent")
            }
            id.value
        case _ => throw IllegalStateException("HTTP parent is not a canonical ToolCall")
    }
    let provenance = decodeStoredProvenance(row.required(7))
    // The caller permits only existing cancellation obligations here.
    // Admission, markExecuting and handoff retain their running-only fence.
    requireHostServiceOriginBinding(transaction, OperationId(parentId), runId, ItemId(row.required(2)),
        allowCancellingSettlement: allowCancellingSettlement)
    if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != runId.value) {
        throw IllegalStateException("HTTP parent canonical provenance belongs to another Run")
    }
    let decision = transaction.query(
        "SELECT d.id,b.scoped_tool_call_id FROM decision_operations source " +
            "JOIN model_decisions d ON d.id=source.decision_id " +
            "JOIN model_decision_blocks b ON b.decision_id=d.id " +
            " AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
            "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
            "JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
            "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? " +
            "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
        [SqlParameter.Text(parentId), SqlParameter.Text(row.required(2)), SqlParameter.Text(runId.value)]
    )
    let sourceKind: String
    var decisionId = ""
    var scopedCallId = ""
    if (provenance.source == "direct_tool") {
        if (provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != parentId ||
            !decision.isEmpty() || !transaction.query(
                "SELECT decision_id FROM canonical_decision_items WHERE item_id=?",
                [SqlParameter.Text(row.required(2))]).isEmpty() || !transaction.query(
                "SELECT decision_id FROM decision_operations WHERE operation_id=?",
                [SqlParameter.Text(parentId)]).isEmpty()) {
            throw IllegalStateException("HTTP Direct parent has forged or ambiguous provenance")
        }
        sourceKind = "direct"
    } else {
        if (decision.size != 1 || provenance.operationId.isSome()) {
            throw IllegalStateException("HTTP Committed parent has no unique validated model source")
        }
        sourceKind = "committed"
        decisionId = decision[0].required(0)
        scopedCallId = decision[0].required(1)
    }
    let evidence = objectValue([
        ValueField("authorization_source", textValue(if (readOnlyProposal) { "readonly_derived" } else { "parent_intent" })),
        ValueField("root_source", textValue(sourceKind)),
        ValueField("thread_id", textValue(row.required(3))),
        ValueField("turn_id", textValue(row.required(4))),
        ValueField("run_id", textValue(runId.value)),
        ValueField("epoch", textValue(row.required(5))),
        ValueField("root_item_id", textValue(row.required(2))),
        ValueField("root_call_id", textValue(callId)),
        ValueField("decision_id", textValue(decisionId)),
        ValueField("scoped_tool_call_id", textValue(scopedCallId)),
        ValueField("parent_operation_id", textValue(parentId)),
        ValueField("parent_handoff_id", textValue(row.required(9))),
        ValueField("parent_plan_digest", textValue(parentPlan.bindingDigest)),
        ValueField("child_operation_id", textValue(operationId.value)),
        ValueField("child_plan_digest", textValue(childPlan.bindingDigest)),
        ValueField("request_key", textValue(row.required(8))),
        ValueField("intent_id", textValue(if (readOnlyProposal) { "" } else { httpIntentText(
            childPlan.canonicalArguments.field("intent").getOrThrow(), "id") }))
    ])
    if (childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
        evidence.put("document_intent_digest", textValue(modelPolicySha256Text(encodeOperationPlan(childPlan))))
    }
    match (provenance.directOrigin) {
        case Some(origin) => evidence.put("root_origin", directCallOriginValue(origin))
        case None => ()
    }
    evidence
}

func requireExactParentIntentInTransaction204(
    transaction: SqliteTransaction,
    operationId: OperationId,
    runId: RunId,
    plan: NormalizedOperationPlan,
    allowCancellingSettlement!: Bool = false,
    completedDocumentChild!: Bool = false,
    documentPayloadAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None
): Unit {
    if (requireReadonlyDerivedIntent(transaction, operationId, runId, plan, allowCancellingSettlement).isSome()) { return }
    if (plan.toolName == "host.file.plan.propose" && plan.canonicalArguments.field("managed_binding").isSome()) {
        // Reuse exact canonical source/epoch/startup checks, without minting
        // ParentIntent authorization for a proposal that was not frozen in
        // the root. The existing read-only policy decision remains required.
        let _ = exactParentIntentEvidenceInTransaction204(transaction, operationId, runId, plan,
            allowCancellingSettlement: allowCancellingSettlement, documentPayloadAllocation: documentPayloadAllocation)
        return
    }
    if (plan.toolName != HOST_PLUGIN_CHILD_TOOL111 && plan.toolName != HOST_HTTP_SERVICE_TOOL && plan.toolName != HOST_CHANNEL_WRITE_TOOL && plan.toolName != HOST_HTTP_STREAM_TOOL && plan.toolName != HOST_READ_VIEW_TOOL && plan.toolName != HOST_PLUGIN_DOCUMENT_TOOL) { return }
    let expected = exactParentIntentEvidenceInTransaction204(transaction, operationId, runId, plan,
        allowCancellingSettlement: allowCancellingSettlement, completedDocumentChild: completedDocumentChild,
        documentPayloadAllocation: documentPayloadAllocation)
    let evidence = transaction.query(
        "SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? " +
            "AND kind='operation_parent_intent_authorized'",
        [SqlParameter.Text(operationId.value)]
    )
    if (evidence.size != 1 || evidence[0].required(0) != httpIntentText(expected, "thread_id") ||
        evidence[0].required(1) != runId.value || evidence[0].required(2) != encodeStoredValue(expected)) {
        throw IllegalStateException("service ParentIntent authorization is absent or changed before execution")
    }
}
