package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

// An already completed startup permits the host to retain a process, not to
// write arbitrary future bytes. This proof only connects that exact retained
// lease to the separate current parent intent and its normal authorization.
func requireChannelStartupReceipt(transaction: SqliteTransaction, binding: AgentValue, parent: NormalizedOperationPlan): Unit {
    let operationId = httpIntentText(binding, "startup_operation_id")
    let rows = transaction.query("SELECT o.run_id,o.tool_call_item_id,o.normalized_plan,o.state,s.state,e.normalized_plan," +
        "r.thread_id,r.turn_id,r.epoch,r.state,call.payload,call.provenance,initial.kind,initial.provenance,initial.id," +
        "turn.state,COALESCE(turn.active_run_id,''),COALESCE(thread.active_turn_id,'') " +
        "FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id " +
        "JOIN runs r ON r.id=o.run_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "JOIN threads thread ON thread.id=r.thread_id " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN items initial ON initial.id=turn.user_item_id AND initial.thread_id=r.thread_id AND initial.turn_id=r.turn_id " +
        "WHERE o.id=? AND call.kind='tool_call'", [SqlParameter.Text(operationId)])
    channelStoreRequire(rows.size == 1)
    let row = rows[0]
    channelStoreRequire(row.required(3) == "committed" && row.required(4) == "committed" &&
        row.required(9) == "completed" && row.required(15) == "completed" && row.required(16) == "" &&
        row.required(17) != row.required(7) && row.required(2) == row.required(5) &&
        row.required(6) != httpIntentText(binding, "target_thread_id"))
    let plan = decodeOperationPlan(row.required(2))
    let grant = plan.canonicalArguments
    channelStoreRequire(serviceReadOnlyGrantAllows(grant, binding, parent))
    channelStoreRequire(plan.toolName == "host.plugin.lifecycle.start" &&
        plan.implementation.implementationFingerprint == "host-plugin-lifecycle-v1" &&
        plan.effectClass == OperationEffectClass.ExternalMutation && plan.retryDisposition == OperationRetryDisposition.Never &&
        modelPolicySha256Text(canonicalAgentValue(grant)) == httpIntentText(binding, "launch_digest") &&
        httpIntentText(grant, "namespace") == httpIntentText(binding, "plugin") &&
        httpIntentText(grant, "thread_id") == httpIntentText(binding, "target_thread_id"))
    channelStoreRequire(match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false })
    let startupCeiling = CapabilitySet(values: plan.requiredCapabilities)
    let required = channelServiceRequiredCapabilities(binding).value().getOrThrow()
    for (capability in required) {
        channelStoreRequire(startupCeiling.allows(capability.kind, resource: capability.resource))
    }
    channelStoreRequire(networkPoliciesEqual(plan.networkPolicy,
        parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow()))
    for (key in ["package_digest", "configuration_digest", "instance_identity", "permission_domain", "workspace_root", "workspace_mode"]) {
        channelStoreRequire(httpIntentText(grant, key) == httpIntentText(binding, key))
    }
    channelStoreRequire(canonicalAgentValue(grant.field("network").getOrThrow()) ==
        canonicalAgentValue(binding.field("network").getOrThrow()))
    let callProvenance = decodeStoredProvenance(row.required(11))
    let initialProvenance = decodeStoredProvenance(row.required(13))
    let origin = effectiveDirectCallOrigin(callProvenance)
    let service = match (origin) {
        case DirectCallOrigin.HostService(value) => value
        case _ => throw IllegalStateException("channel startup has no host service origin")
    }
    channelStoreRequire(service.action == HostServiceAction.Start &&
        service.ownerNamespace == httpIntentText(binding, "plugin") &&
        service.packageDigest == httpIntentText(binding, "package_digest") &&
        service.configurationDigest == httpIntentText(binding, "configuration_digest") &&
        service.instanceIdentity == httpIntentText(binding, "instance_identity") &&
        service.serviceId == httpIntentText(grant, "service_id") &&
        row.required(12) == "system_note" && initialProvenance.source == "host_service" &&
        initialProvenance.runId.isSome() && initialProvenance.runId.getOrThrow().value == row.required(0) &&
        initialProvenance.operationId.isNone() && sameDirectCallOrigin(effectiveDirectCallOrigin(initialProvenance), origin) &&
        callProvenance.source == "direct_tool" && callProvenance.runId.isSome() &&
        callProvenance.runId.getOrThrow().value == row.required(0) && callProvenance.operationId.isSome() &&
        callProvenance.operationId.getOrThrow().value == operationId)
    let callId = match (decodeStoredThreadContent(row.required(10))) {
        case ThreadItemContent.ToolCall(id, name, arguments) =>
            channelStoreRequire(name == plan.toolName && canonicalAgentValue(arguments) == canonicalAgentValue(grant))
            id.value
        case _ => throw IllegalStateException("channel startup ToolCall is missing")
    }
    channelStoreRequire(transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=?",
        [SqlParameter.Text(operationId)]).isEmpty() &&
        transaction.query("SELECT operation_id FROM decision_operations WHERE operation_id=?", [SqlParameter.Text(operationId)]).isEmpty() &&
        transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?", [SqlParameter.Text(row.required(1))]).isEmpty())
    let handoffs = transaction.query("SELECT id FROM audit_events WHERE kind='operation_execution_handoff' " +
        "AND operation_id=? AND run_id=? AND thread_id=?", [SqlParameter.Text(operationId),
        SqlParameter.Text(row.required(0)), SqlParameter.Text(row.required(6))])
    channelStoreRequire(handoffs.size == 1)
    let audits = transaction.query("SELECT payload FROM audit_events WHERE kind='operation_host_origin_bound' " +
        "AND operation_id=? AND run_id=? AND thread_id=?", [SqlParameter.Text(operationId),
        SqlParameter.Text(row.required(0)), SqlParameter.Text(row.required(6))])
    let evidence = encodeStoredValue(objectValue([
        ValueField("origin", directCallOriginValue(origin)), ValueField("thread_id", textValue(row.required(6))),
        ValueField("turn_id", textValue(row.required(7))), ValueField("run_id", textValue(row.required(0))),
        ValueField("epoch", textValue(row.required(8))), ValueField("initiator_item_id", textValue(row.required(14))),
        ValueField("tool_call_item_id", textValue(row.required(1))), ValueField("operation_id", textValue(operationId)),
        ValueField("call_digest", textValue(modelPolicySha256Text(row.required(10))))]))
    channelStoreRequire(audits.size == 1 && audits[0].required(0) == evidence)
    let receipts = transaction.query("SELECT id,outcome,detail FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(operationId)])
    channelStoreRequire(receipts.size == 1 && receipts[0].required(1) == "completed")
    let summary = decodeStoredValue(receipts[0].required(2))
    channelStoreRequire(httpIntentExactFields(summary, ["lease_id", "launch_digest", "result"]) &&
        httpIntentText(summary, "lease_id") == httpIntentText(binding, "lease_id") &&
        httpIntentText(summary, "launch_digest") == httpIntentText(binding, "launch_digest"))
    let results = transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(row.required(6)), SqlParameter.Text(row.required(7))])
    var matches: Int64 = 0
    for (result in results) {
        match (decodeStoredThreadContent(result.required(0))) {
            case ThreadItemContent.ToolResult(id, operation, receipt, output, isError) =>
                if (operation.value == operationId) {
                    channelStoreRequire(!isError && id.value == callId && receipt == receipts[0].required(0) &&
                        canonicalAgentValue(output) == canonicalAgentValue(summary))
                    matches += 1
                }
            case _ => ()
        }
    }
    channelStoreRequire(matches == 1)
}

func channelStoreRequire(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("channel intent has no exact completed canonical startup") }
}
