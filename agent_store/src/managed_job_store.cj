package agent_store

import agent_domain.*
import agent_runtime.*
import std.time.*
import yjson.*
import yjson_support.*

// All mutations below run in the existing Operation database transaction. Audit
// witnesses bind existing facts; job status and budget stay in TaskRuntime.
func managedJobAuditValue(binding: ManagedJobLaunchBinding, callPayload: String, provenance: String): AgentValue {
    objectValue([ValueField("binding", managedJobLaunchBindingValue(binding)),
        ValueField("call_digest", textValue(modelPolicySha256Text(callPayload))),
        ValueField("provenance_digest", textValue(modelPolicySha256Text(provenance)))])
}

func reserveManagedJobLaunchInTransaction(transaction: SqliteTransaction, source: OperationRootSource,
    operationId: OperationId, runId: RunId, threadId: ThreadId, epoch: Int64,
    frozen: NormalizedOperationPlan, now: Int64): ManagedJobLaunchBinding {
    channelStoreRequire(isManagedJobLaunchPlan(frozen))
    match (source) {
        case OperationRootSource.Direct(value) => match (value.origin) {
            case DirectCallOrigin.UserDirect => ()
            case _ => throw IllegalStateException("only ordinary approved calls may delegate a managed job")
        }
        case OperationRootSource.Committed(_) => ()
    }
    let host = frozen.canonicalArguments.field("host_plan").getOrThrow()
    let serviceBinding = host.field("binding").getOrThrow()
    requireChannelInvocationRoot(transaction, operationId, runId, threadId, epoch, source, frozen, serviceBinding)
    let declaration = managedJobDeclarationFromValue(host.field("managed_job").getOrThrow())
    channelStoreRequire(declaration.deadlineMillis > now && declaration.deadlineMillis - now <= 3600000 &&
        declaration.threadId.value != threadId.value && declaration.runId.value != runId.value)
    // The launch may not consume any intended command bytes itself. A delegated
    // job cannot inherit a partly executed batch or disguise a nested child.
    channelStoreRequire(transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?",
        [SqlParameter.Text(operationId.value)]).isEmpty())
    channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='managed_job_reserved'",
        [SqlParameter.Text(operationId.value)]).isEmpty())
    channelStoreRequire(transaction.query("SELECT id FROM runs WHERE id=?", [SqlParameter.Text(declaration.runId.value)]).isEmpty())
    // Constant-size identity witnesses use existing indexed audit kinds. Do
    // not materialize an ever-growing history to detect a collision.
    for (key in managedJobIdentityKeys(declaration)) {
        channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE kind=?", [SqlParameter.Text(key)]).isEmpty())
    }
    let binding = ManagedJobLaunchBinding(declaration, threadId, runId, epoch, operationId, source.itemId(), source.callId(),
        modelPolicySha256Text(encodeOperationPlan(frozen)), httpIntentText(serviceBinding, "permission_domain"),
        modelPolicySha256Text(canonicalAgentValue(serviceBinding)))
    let call = transaction.query("SELECT payload,provenance FROM items WHERE id=?", [SqlParameter.Text(source.itemId().value)])
    channelStoreRequire(call.size == 1)
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES (?,?,?,'managed_job_reserved',?,?)", [SqlParameter.Text(threadId.value), SqlParameter.Text(runId.value),
        SqlParameter.Text(operationId.value), SqlParameter.Text(encodeStoredValue(managedJobAuditValue(binding,
            call[0].required(0), call[0].required(1)))), SqlParameter.Int64Value(now)])
    for (key in managedJobIdentityKeys(declaration)) {
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,?)",
            [SqlParameter.Text(threadId.value), SqlParameter.Text(runId.value), SqlParameter.Text(operationId.value),
            SqlParameter.Text(key), SqlParameter.Text(managedJobLaunchDigest(binding)), SqlParameter.Int64Value(now)])
    }
    binding
}

func managedJobIdentityKeys(value: ManagedJobDeclaration): Array<String> {
    ["managed_job_identity:job:" + modelPolicySha256Text(value.jobId),
        "managed_job_identity:thread:" + modelPolicySha256Text(value.threadId.value),
        "managed_job_identity:run:" + modelPolicySha256Text(value.runId.value)]
}

func requireManagedJobCompletedParent(transaction: SqliteTransaction, binding: ManagedJobLaunchBinding, now: Int64, settlement!: Bool = false): Unit {
    channelStoreRequire(settlement || binding.declaration.deadlineMillis > now)
    let rows = transaction.query("SELECT o.normalized_plan,o.state,s.state,e.normalized_plan,r.thread_id,r.turn_id,r.epoch,r.state," +
        "call.payload,call.provenance FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id " +
        "JOIN runs r ON r.id=o.run_id JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "WHERE o.id=? AND o.run_id=? AND call.id=? AND call.kind='tool_call'",
        [SqlParameter.Text(binding.parentOperationId.value), SqlParameter.Text(binding.parentRunId.value), SqlParameter.Text(binding.parentItemId.value)])
    channelStoreRequire(rows.size == 1)
    let row = rows[0]
    channelStoreRequire(row.required(1) == "committed" && row.required(2) == "committed" && row.required(0) == row.required(3) &&
        modelPolicySha256Text(row.required(0)) == binding.planDigest && row.required(4) == binding.parentThreadId.value &&
        row.required(6) == binding.parentEpoch.toString() &&
        (settlement || ["running", "waiting_approval", "waiting_external", "completed"].contains(row.required(7))))
    for (key in managedJobIdentityKeys(binding.declaration)) {
        let identities = transaction.query("SELECT operation_id,run_id,thread_id,payload FROM audit_events WHERE kind=?", [SqlParameter.Text(key)])
        channelStoreRequire(identities.size == 1 && identities[0].required(0) == binding.parentOperationId.value &&
            identities[0].required(1) == binding.parentRunId.value && identities[0].required(2) == binding.parentThreadId.value &&
            identities[0].required(3) == managedJobLaunchDigest(binding))
    }
    let plan = decodeOperationPlan(row.required(0))
    channelStoreRequire(isManagedJobLaunchPlan(plan))
    let host = plan.canonicalArguments.field("host_plan").getOrThrow()
    let serviceBinding = host.field("binding").getOrThrow()
    channelStoreRequire(canonicalAgentValue(host.field("managed_job").getOrThrow()) ==
        canonicalAgentValue(managedJobDeclarationValue(binding.declaration)) &&
        modelPolicySha256Text(canonicalAgentValue(serviceBinding)) == binding.serviceBindingDigest &&
        httpIntentText(serviceBinding, "permission_domain") == binding.permissionDomain &&
        httpIntentText(serviceBinding, "target_thread_id") == binding.parentThreadId.value)
    requireChannelStartupReceipt(transaction, serviceBinding, plan)
    let audits = transaction.query("SELECT payload FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind='managed_job_reserved'",
        [SqlParameter.Text(binding.parentThreadId.value), SqlParameter.Text(binding.parentRunId.value), SqlParameter.Text(binding.parentOperationId.value)])
    channelStoreRequire(audits.size == 1 && audits[0].required(0) == encodeStoredValue(managedJobAuditValue(binding, row.required(8), row.required(9))))
    let handoff = transaction.query("SELECT payload FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind='operation_execution_handoff'",
        [SqlParameter.Text(binding.parentThreadId.value), SqlParameter.Text(binding.parentRunId.value), SqlParameter.Text(binding.parentOperationId.value)])
    channelStoreRequire(handoff.size == 1 && handoff[0].required(0) == encodeStoredValue(objectValue([
        ValueField("channel_parent_epoch", textValue(binding.parentEpoch.toString())), ValueField("parent_plan_digest", textValue(plan.bindingDigest))])))
    channelStoreRequire(transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?",
        [SqlParameter.Text(binding.parentOperationId.value)]).isEmpty())
    let receipts = transaction.query("SELECT id,outcome,detail FROM operation_receipts WHERE operation_id=?",
        [SqlParameter.Text(binding.parentOperationId.value)])
    channelStoreRequire(receipts.size == 1 && receipts[0].required(1) == "completed" &&
        canonicalAgentValue(decodeStoredValue(receipts[0].required(2))) == canonicalAgentValue(managedJobLaunchOutput(binding)))
    let results = transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(binding.parentThreadId.value), SqlParameter.Text(row.required(5))])
    var matches: Int64 = 0
    for (result in results) {
        match (decodeStoredThreadContent(result.required(0))) {
            case ThreadItemContent.ToolResult(id, operation, receipt, output, isError) => if (operation.value == binding.parentOperationId.value) {
                channelStoreRequire(!isError && id.value == binding.parentCallId && receipt == receipts[0].required(0) &&
                    canonicalAgentValue(output) == canonicalAgentValue(managedJobLaunchOutput(binding)))
                matches += 1
            }
            case _ => ()
        }
    }
    channelStoreRequire(matches == 1)
}

func managedJobClaimValue(binding: ManagedJobLaunchBinding): String {
    encodeStoredValue(objectValue([ValueField("schema", textValue("axyndra.managed-job-claim/v1")),
        ValueField("launch_digest", textValue(managedJobLaunchDigest(binding))),
        ValueField("job", managedJobDeclarationValue(binding.declaration))]))
}

func claimManagedJobLaunchInTransaction(transaction: SqliteTransaction, binding: ManagedJobLaunchBinding, now: Int64): Unit {
    requireManagedJobCompletedParent(transaction, binding, now)
    channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='managed_job_claimed'",
        [SqlParameter.Text(binding.parentOperationId.value)]).isEmpty())
    channelStoreRequire(transaction.query("SELECT id FROM runs WHERE id=?", [SqlParameter.Text(binding.declaration.runId.value)]).isEmpty())
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES (?,?,?,'managed_job_claimed',?,?)", [SqlParameter.Text(binding.parentThreadId.value),
        SqlParameter.Text(binding.parentRunId.value), SqlParameter.Text(binding.parentOperationId.value),
        SqlParameter.Text(managedJobClaimValue(binding)), SqlParameter.Int64Value(now)])
}

func verifyManagedJobLaunchInTransaction(transaction: SqliteTransaction, binding: ManagedJobLaunchBinding, now: Int64, settlement!: Bool = false): Unit {
    requireManagedJobCompletedParent(transaction, binding, now, settlement: settlement)
    let claims = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='managed_job_claimed'",
        [SqlParameter.Text(binding.parentOperationId.value), SqlParameter.Text(binding.parentRunId.value), SqlParameter.Text(binding.parentThreadId.value)])
    channelStoreRequire(claims.size == 1 && claims[0].required(0) == managedJobClaimValue(binding))
}

// A child Run retains its real Thread/epoch. The original publication scope is
// read only from this immutable, canonically committed Task source; no payload
// or arbitrary Thread argument can select another directory.
func requireManagedJobOriginBinding(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, item: ItemId, binding: ManagedJobLaunchBinding,
    bindIfMissing!: Bool = false, allowCancellingSettlement!: Bool = false): Unit {
    verifyManagedJobLaunchInTransaction(transaction, binding,
        DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(), settlement: allowCancellingSettlement)
    let rows = transaction.query("SELECT r.thread_id,r.turn_id,r.epoch,r.state,r.budget,call.payload,call.provenance," +
        "initial.id,initial.kind,initial.provenance FROM runs r JOIN threads thread ON thread.id=r.thread_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "JOIN items initial ON initial.id=turn.user_item_id AND initial.thread_id=r.thread_id AND initial.turn_id=r.turn_id " +
        "JOIN items call ON call.id=? AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "WHERE r.id=? AND call.kind='tool_call' AND thread.active_turn_id=r.turn_id AND turn.active_run_id=r.id",
        [SqlParameter.Text(item.value), SqlParameter.Text(run.value)])
    channelStoreRequire(rows.size == 1)
    let row = rows[0]
    let expected = DirectCallOrigin.ManagedJob(binding)
    let callOrigin = decodeStoredProvenance(row.required(6))
    let initial = decodeStoredProvenance(row.required(9))
    channelStoreRequire(run.value == binding.declaration.runId.value && row.required(0) == binding.declaration.threadId.value &&
        (row.required(3) == "running" || (allowCancellingSettlement && row.required(3) == "cancelling")) &&
        canonicalAgentValue(decodeStoredValue(row.required(4))) == canonicalAgentValue(managedJobRunBudget(binding)) &&
        row.required(8) == "system_note" && initial.source == "managed_job" && initial.runId.isSome() &&
        initial.runId.getOrThrow().value == run.value && initial.operationId.isNone() &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(initial), expected) &&
        callOrigin.source == "direct_tool" && callOrigin.runId.isSome() && callOrigin.runId.getOrThrow().value == run.value &&
        callOrigin.operationId.isSome() && callOrigin.operationId.getOrThrow().value == operation.value &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(callOrigin), expected))
    let original = transaction.query("SELECT payload FROM items WHERE id=?", [SqlParameter.Text(binding.parentItemId.value)])
    channelStoreRequire(original.size == 1 && original[0].required(0) == row.required(5))
    // One canonical execution per claimed job, even if a caller fabricates a
    // second provenance record through a lower-level Store interface.
    let peers = transaction.query("SELECT id FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_call'",
        [SqlParameter.Text(row.required(0)), SqlParameter.Text(row.required(1))])
    channelStoreRequire(peers.size == 1 && peers[0].required(0) == item.value)
    channelStoreRequire(transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?", [SqlParameter.Text(item.value)]).isEmpty())
    let evidence = encodeStoredValue(objectValue([
        ValueField("origin", directCallOriginValue(expected)), ValueField("thread_id", textValue(row.required(0))),
        ValueField("turn_id", textValue(row.required(1))), ValueField("run_id", textValue(run.value)),
        ValueField("epoch", textValue(row.required(2))), ValueField("initiator_item_id", textValue(row.required(7))),
        ValueField("tool_call_item_id", textValue(item.value)), ValueField("operation_id", textValue(operation.value)),
        ValueField("call_digest", textValue(modelPolicySha256Text(row.required(5))))]))
    let audits = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind='operation_managed_job_origin_bound'",
        [SqlParameter.Text(operation.value)])
    if (audits.isEmpty() && bindIfMissing) {
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
            "VALUES (?,?,?,'operation_managed_job_origin_bound',?,?)", [SqlParameter.Text(row.required(0)),
            SqlParameter.Text(run.value), SqlParameter.Text(operation.value), SqlParameter.Text(evidence),
            SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())])
    } else { channelStoreRequire(audits.size == 1 && audits[0].required(0) == evidence) }
}

func requireManagedJobPlan(transaction: SqliteTransaction, item: ItemId, plan: NormalizedOperationPlan): Unit {
    let rows = transaction.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(item.value)])
    channelStoreRequire(rows.size == 1)
    match (effectiveDirectCallOrigin(decodeStoredProvenance(rows[0].required(0)))) {
        case DirectCallOrigin.ManagedJob(binding) =>
            let original = transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
                [SqlParameter.Text(binding.parentOperationId.value), SqlParameter.Text(binding.parentRunId.value)])
            channelStoreRequire(original.size == 1 && isManagedJobLaunchPlan(plan) &&
                original[0].required(0) == encodeOperationPlan(plan) && modelPolicySha256Text(encodeOperationPlan(plan)) == binding.planDigest)
        case _ => ()
    }
}

func managedJobServiceThread(transaction: SqliteTransaction, item: ItemId, actualThread: String,
    run: RunId, binding: AgentValue): String {
    let rows = transaction.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(item.value)])
    channelStoreRequire(rows.size == 1)
    match (effectiveDirectCallOrigin(decodeStoredProvenance(rows[0].required(0)))) {
        case DirectCallOrigin.ManagedJob(value) =>
            channelStoreRequire(value.declaration.threadId.value == actualThread && value.declaration.runId.value == run.value &&
                value.serviceBindingDigest == modelPolicySha256Text(canonicalAgentValue(binding)))
            value.parentThreadId.value
        case _ => actualThread
    }
}
