package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// A read-only projection of the ONE canonical operation state machine. This
// creates no grant, source, Run, Receipt or resource. In particular a completed
// startup does not authorize a later HTTP request.
class CompletedHttpMaintenance {
    let runId: String
    let threadId: String
    let turnId: String
    let epoch: String
    let itemId: String
    let callId: String
    let origin: DirectCallOrigin
    let plan: NormalizedOperationPlan
    let output: AgentValue
    init(runId: String, threadId: String, turnId: String, epoch: String, itemId: String,
        callId: String, origin: DirectCallOrigin, plan: NormalizedOperationPlan, output: AgentValue) {
        this.runId = runId; this.threadId = threadId; this.turnId = turnId; this.epoch = epoch
        this.itemId = itemId; this.callId = callId; this.origin = origin; this.plan = plan; this.output = output
    }
}

func requireHttpMaintenanceCompleted(transaction: SqliteTransaction, operationId: String): CompletedHttpMaintenance {
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
        row.required(17) != row.required(7) && row.required(2) == row.required(5))
    let plan = decodeOperationPlan(row.required(2))
    let provenance = decodeStoredProvenance(row.required(11))
    let initial = decodeStoredProvenance(row.required(13))
    let origin = effectiveDirectCallOrigin(provenance)
    let service = match (origin) {
        case DirectCallOrigin.HostService(value) => value
        case _ => throw IllegalStateException("HTTP maintenance requires its actual HostService origin")
    }
    let start = service.action == HostServiceAction.Start
    channelStoreRequire(start || service.action == HostServiceAction.Refresh)
    channelStoreRequire(row.required(12) == "system_note" && initial.source == "host_service" &&
        initial.runId.isSome() && initial.runId.getOrThrow().value == row.required(0) && initial.operationId.isNone() &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(initial), origin) && provenance.source == "direct_tool" &&
        provenance.runId.isSome() && provenance.runId.getOrThrow().value == row.required(0) &&
        provenance.operationId.isSome() && provenance.operationId.getOrThrow().value == operationId)
    let callId = match (decodeStoredThreadContent(row.required(10))) {
        case ThreadItemContent.ToolCall(id, name, arguments) =>
            channelStoreRequire(name == plan.toolName && canonicalAgentValue(arguments) == canonicalAgentValue(plan.canonicalArguments))
            id.value
        case _ => throw IllegalStateException("HTTP maintenance canonical ToolCall is missing")
    }
    channelStoreRequire(service.hostRequestId == callId)
    channelStoreRequire(transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=?",
        [SqlParameter.Text(operationId)]).isEmpty() &&
        transaction.query("SELECT operation_id FROM decision_operations WHERE operation_id=?", [SqlParameter.Text(operationId)]).isEmpty() &&
        transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?", [SqlParameter.Text(row.required(1))]).isEmpty())
    channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE kind='operation_execution_handoff' " +
        "AND operation_id=? AND run_id=? AND thread_id=?", [SqlParameter.Text(operationId),
        SqlParameter.Text(row.required(0)), SqlParameter.Text(row.required(6))]).size == 1)
    let audits = transaction.query("SELECT thread_id,run_id,payload FROM audit_events " +
        "WHERE kind='operation_host_origin_bound' AND operation_id=?", [SqlParameter.Text(operationId)])
    let evidence = encodeStoredValue(objectValue([
        ValueField("origin", directCallOriginValue(origin)), ValueField("thread_id", textValue(row.required(6))),
        ValueField("turn_id", textValue(row.required(7))), ValueField("run_id", textValue(row.required(0))),
        ValueField("epoch", textValue(row.required(8))), ValueField("initiator_item_id", textValue(row.required(14))),
        ValueField("tool_call_item_id", textValue(row.required(1))), ValueField("operation_id", textValue(operationId)),
        ValueField("call_digest", textValue(modelPolicySha256Text(row.required(10))))]))
    channelStoreRequire(audits.size == 1 && audits[0].required(0) == row.required(6) &&
        audits[0].required(1) == row.required(0) && audits[0].required(2) == evidence)
    let receipts = transaction.query("SELECT id,outcome,detail FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(operationId)])
    channelStoreRequire(receipts.size == 1 && receipts[0].required(1) == "completed")
    let output = decodeStoredValue(receipts[0].required(2))
    var matches: Int64 = 0
    for (result in transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(row.required(6)), SqlParameter.Text(row.required(7))])) {
        match (decodeStoredThreadContent(result.required(0))) {
            case ThreadItemContent.ToolResult(id, operation, receipt, value, isError) =>
                if (operation.value == operationId) {
                    channelStoreRequire(!isError && id.value == callId && receipt == receipts[0].required(0) &&
                        canonicalAgentValue(value) == canonicalAgentValue(output))
                    matches += 1
                }
            case _ => ()
        }
    }
    channelStoreRequire(matches == 1)
    requireHttpMaintenanceShape(plan, output, origin)
    CompletedHttpMaintenance(row.required(0), row.required(6), row.required(7), row.required(8),
        row.required(1), callId, origin, plan, output)
}

func requireHttpMaintenanceShape(plan: NormalizedOperationPlan, output: AgentValue, origin: DirectCallOrigin): Unit {
    let service = match (origin) { case DirectCallOrigin.HostService(value) => value
        case _ => throw IllegalStateException("HTTP maintenance origin is not HostService") }
    let start = service.action == HostServiceAction.Start
    let args = plan.canonicalArguments
    channelStoreRequire(plan.toolName == (if (start) { "host.plugin.http.lifecycle" } else { "host.plugin.http.lifecycle.refresh" }) &&
        plan.implementation.implementationFingerprint == (if (start) { "host-plugin-http-lifecycle-v1" }
            else { "host-plugin-http-lifecycle-refresh-v1" }) &&
        plan.implementation.toolVersion == plan.implementation.implementationFingerprint &&
        plan.effectClass == OperationEffectClass.ExternalMutation && plan.retryDisposition == OperationRetryDisposition.Never)
    channelStoreRequire(match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false })
    channelStoreRequire(if (start) { httpIntentExactFields(args, ["grant", "resource_id"]) }
        else { httpIntentExactFields(args, ["schema", "launch", "resource_id", "endpoint_identity", "expected_revision", "directory_digest", "window"]) &&
            httpIntentText(args, "schema") == "axyndra.http-service-refresh/v1" })
    let grant = args.field(if (start) { "grant" } else { "launch" }).getOrThrow()
    channelStoreRequire(serviceEffectGrantFields(grant, ["schema", "namespace", "package_digest", "configuration_digest", "service_id",
        "thread_id", "instance_identity", "permission_domain", "workspace_root", "network", "lifetime_ms", "max_instances", "startup", "refresh"]) &&
        httpIntentText(grant, "schema") == "axyndra.http-service-launch/v1" &&
        service.ownerNamespace == httpIntentText(grant, "namespace") && service.packageDigest == httpIntentText(grant, "package_digest") &&
        service.configurationDigest == httpIntentText(grant, "configuration_digest") && service.serviceId == httpIntentText(grant, "service_id") &&
        service.instanceIdentity == httpIntentText(grant, "instance_identity"))
    let network = parseNetworkPolicy(grant.field("network").getOrThrow()).value().getOrThrow()
    channelStoreRequire(network.mode == NetworkPolicyMode.Mediated && !network.egress.isEmpty() && network.publish.isEmpty() &&
        networkPoliciesEqual(network, plan.networkPolicy))
    let ceiling = CapabilitySet(values: plan.requiredCapabilities)
    channelStoreRequire(ceiling.allows(CapabilityKind.ExtensionInvoke))
    for (rule in network.egress) { channelStoreRequire(ceiling.allows(CapabilityKind.NetworkAccess, resource: networkEgressResource(rule))) }
    channelStoreRequire(if (start) { httpIntentExactFields(output, ["schema", "resource_id", "grant_digest", "endpoint_identity", "directory"]) }
        else { httpIntentExactFields(output, ["schema", "resource_id", "grant_digest", "endpoint_identity", "expected_revision", "directory"]) })
    channelStoreRequire(httpIntentText(output, "schema") == (if (start) { "axyndra.http-service-start-result/v1" }
            else { "axyndra.http-service-refresh-result/v1" }) &&
        httpIntentText(output, "resource_id") == httpIntentText(args, "resource_id") &&
        channelIntentIdentifier(httpIntentText(output, "resource_id")) && httpIntentDigest(httpIntentText(output, "endpoint_identity")) &&
        httpIntentText(output, "grant_digest") == modelPolicySha256Text(canonicalAgentValue(grant)))
    if (!start) {
        channelStoreRequire(httpIntentText(output, "endpoint_identity") == httpIntentText(args, "endpoint_identity") &&
            canonicalAgentValue(output.field("expected_revision").getOrThrow()) == canonicalAgentValue(args.field("expected_revision").getOrThrow()) &&
            canonicalAgentValue(args.field("window").getOrThrow()) == canonicalAgentValue(grant.field("refresh").getOrThrow()))
    }
}

func requireHttpStreamStartupReceipt(transaction: SqliteTransaction, binding: AgentValue, parent: NormalizedOperationPlan): Unit {
    channelStoreRequire(validateHttpStreamBinding(binding).isOk())
    let completed = requireHttpMaintenanceCompleted(transaction, httpIntentText(binding, "startup_operation_id"))
    channelStoreRequire(completed.plan.toolName == "host.plugin.http.lifecycle" &&
        completed.threadId != httpIntentText(binding, "target_thread_id"))
    let grant = completed.plan.canonicalArguments.field("grant").getOrThrow()
    channelStoreRequire(serviceReadOnlyGrantAllows(grant, binding, parent))
    channelStoreRequire(httpIntentText(grant, "namespace") == httpIntentText(binding, "plugin") &&
        httpIntentText(grant, "thread_id") == httpIntentText(binding, "target_thread_id") &&
        httpIntentText(completed.output, "resource_id") == httpIntentText(binding, "resource_id") &&
        httpIntentText(completed.output, "endpoint_identity") == httpIntentText(binding, "endpoint_identity") &&
        httpIntentText(completed.output, "grant_digest") == httpIntentText(binding, "grant_digest"))
    for (key in ["package_digest", "configuration_digest", "instance_identity", "permission_domain", "workspace_root"]) {
        channelStoreRequire(httpIntentText(grant, key) == httpIntentText(binding, key))
    }
    channelStoreRequire(canonicalAgentValue(grant.field("network").getOrThrow()) == canonicalAgentValue(binding.field("network").getOrThrow()))
}
