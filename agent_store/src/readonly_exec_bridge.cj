package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Routing predicate only. An ordinary root acquires no new plan kind or
// synthetic handoff. Its existing Source, effect and actual handoff remain.
func isHostReadonlyExecRoot(plan: NormalizedOperationPlan): Bool {
    isSupportedDerivedParentPlan(plan, plan.toolName) && !isFrozenExactParentPlan(plan)
}

func loadReadonlyExecSelection(transaction: SqliteTransaction, operation: OperationId, run: RunId): ?AgentValue {
    loadReadonlyExecSelectionQuery({ sql, parameters => transaction.query(sql, parameters) }, operation, run)
}

func loadReadonlyExecSelectionQuery(query: (String, Array<SqlParameter>) -> Array<SqliteRow>,
    operation: OperationId, run: RunId): ?AgentValue {
    let rows = query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? " +
        "AND kind='operation_parent_intent_authorized'", [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    if (rows.isEmpty()) { return None<AgentValue> }
    if (rows.size != 1) { throw IllegalStateException("readonly bridge has ambiguous canonical authorization") }
    let evidence = decodeStoredValue(rows[0].required(0))
    let selection = evidence.field("readonly_exec_selection")
    if (selection.isSome() && httpIntentText(selection.getOrThrow(), "run_id") != run.value) {
        throw IllegalStateException("readonly bridge selection changed its canonical Run") }
    if (selection.isSome() && httpIntentText(evidence, "authorization_source") != "host_readonly_exec") {
        throw IllegalStateException("readonly bridge selection changed its canonical family") }
    selection
}

// Revalidation can observe a recorded Host choice, but cannot use it to
// mint another Operation, parent edge, or request. Full ancestry and immutable
// plan/audit comparison still run in prepareReadonlyDerivedOperation.
func readonlyExecReplaySelection(transaction: SqliteTransaction, operation: OperationId,
    parent: OperationId, run: RunId, requestKey: String): ?AgentValue {
    let rows = transaction.query("SELECT a.operation_id FROM derived_operation_admissions a " +
        "JOIN operations o ON o.id=a.operation_id WHERE a.operation_id=? AND a.parent_operation_id=? " +
        "AND a.request_key=? AND o.run_id=?", [SqlParameter.Text(operation.value),
            SqlParameter.Text(parent.value), SqlParameter.Text(requestKey), SqlParameter.Text(run.value)])
    if (rows.isEmpty()) { return None<AgentValue> }
    if (rows.size != 1) { throw IllegalStateException("readonly bridge replay has ambiguous identity") }
    loadReadonlyExecSelection(transaction, operation, run)
}

func readonlyExecEdgeAllowed(parent: ReadonlyDerivedNode, child: ReadonlyDerivedNode): Bool {
    let selected = match (child.readonlyExecSelection) { case Some(value) => value; case None => return false }
    if (parent.parent != "" || !isHostReadonlyExecRoot(parent.plan) || child.depth != 1 ||
        !isReadonlyDelegatedChildPlan(child.plan) ||
        !httpIntentExactFields(selected, ["schema", "run_id", "thread_id", "epoch", "target", "version",
            "fingerprint", "schema_digest", "package_digest", "generation", "configuration_digest"]) ||
        httpIntentText(selected, "schema") != "host-readonly-exec/v1" ||
        httpIntentText(selected, "thread_id") != parent.thread.value ||
        httpIntentText(selected, "epoch") != parent.epoch.toString() ||
        httpIntentText(selected, "target") != child.plan.toolName ||
        httpIntentText(selected, "version") != child.plan.implementation.toolVersion ||
        httpIntentText(selected, "fingerprint") != child.plan.implementation.implementationFingerprint ||
        httpIntentText(selected, "schema_digest") != child.plan.implementation.schemaDigest) { return false }
    let prefix = "javascript-service:" + parent.callId + ":"
    if (!child.requestKey.startsWith(prefix) || child.requestKey.size <= prefix.size ||
        child.callId != parent.callId + ":service:" + child.requestKey[prefix.size..]) { return false }
    let frozen = child.plan.canonicalArguments.field("host_plan").getOrThrow()
    for (field in ["package_digest", "generation", "configuration_digest"] where
        httpIntentText(selected, field) != httpIntentText(frozen, field)) { return false }
    let ceiling = CapabilitySet(values: parent.plan.requiredCapabilities)
    if (!ceiling.allows(CapabilityKind.ExtensionInvoke, resource: child.plan.toolName)) { return false }
    for (cap in child.plan.requiredCapabilities where !ceiling.allows(cap.kind, resource: cap.resource)) { return false }
    true
}

func hasReadonlyExecChildren(transaction: SqliteTransaction, operation: OperationId, run: RunId): Bool {
    let rows = transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?",
        [SqlParameter.Text(operation.value)])
    for (row in rows where loadReadonlyExecSelection(transaction, OperationId(row.required(0)), run).isSome()) { return true }
    false
}
