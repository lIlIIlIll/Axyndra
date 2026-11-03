package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// This is a transaction-local read of the existing Operation graph, never an
// authority registry or a durable object that can be replayed as a live seal.
class ReadonlyDerivedNode {
    let operation: OperationId
    let parent: String
    let root: String
    let depth: Int64
    let callId: String
    let requestKey: String
    let plan: NormalizedOperationPlan
    let item: ItemId
    let thread: ThreadId
    let turn: SemanticTurnId
    let epoch: Int64
    let call: ToolCall
    let provenance: ItemProvenance
    let state: String
    init(operation: OperationId, parent: String, root: String, depth: Int64, callId: String,
        requestKey: String, plan: NormalizedOperationPlan, item: ItemId, thread: ThreadId,
        turn: SemanticTurnId, epoch: Int64, call: ToolCall, provenance: ItemProvenance, state: String) {
        this.operation = operation; this.parent = parent; this.root = root; this.depth = depth
        this.callId = callId; this.requestKey = requestKey; this.plan = plan; this.item = item
        this.thread = thread; this.turn = turn; this.epoch = epoch; this.call = call
        this.provenance = provenance; this.state = state
    }
}

class ReadonlyDerivedAncestry {
    // Root first, immediate parent last. Every entry is in this same SQL Tx.
    let ancestors: Array<ReadonlyDerivedNode>
    let decisionId: String
    let scopedCallId: String
    let settlementOnly: Bool
    init(ancestors: Array<ReadonlyDerivedNode>, decisionId: String, scopedCallId: String,
        settlementOnly!: Bool = false) {
        this.ancestors = ancestors; this.decisionId = decisionId; this.scopedCallId = scopedCallId
        this.settlementOnly = settlementOnly
    }
    prop root: ReadonlyDerivedNode { get() { ancestors[0] } }
    prop parent: ReadonlyDerivedNode { get() { ancestors[ancestors.size - 1] } }
}

func loadReadonlyDerivedNode(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, allowCancelling: Bool): ReadonlyDerivedNode {
    let rows = transaction.query(
        "SELECT o.normalized_plan,o.tool_call_item_id,o.state,r.thread_id,r.turn_id,r.epoch,item.payload,item.provenance," +
        "COALESCE(a.parent_operation_id,''),COALESCE(a.root_operation_id,''),COALESCE(a.depth,0)," +
        "COALESCE(a.child_call_id,''),COALESCE(a.request_key,''),COALESCE(a.request_digest,'') " +
        "FROM operations o JOIN runs r ON r.id=o.run_id " +
        "JOIN threads thread ON thread.id=r.thread_id AND thread.active_turn_id=r.turn_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id AND turn.active_run_id=r.id AND turn.state='active' " +
        "JOIN items item ON item.id=o.tool_call_item_id AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
        "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=r.id " +
        "AND effect.tool_call_item_id=item.id AND effect.normalized_plan=o.normalized_plan " +
        "JOIN operation_state_registers register ON register.operation_id=o.id AND register.state=o.state " +
        "LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id " +
        "WHERE o.id=? AND r.id=? AND item.kind='tool_call' AND r.finished_at_millis IS NULL " +
        "AND r.state IN (" + (if (allowCancelling) { "'running','cancelling'" } else { "'running'" }) + ")",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("readonly tree lost its current Run, exact effect plan, or state mirror") }
    let row = rows[0]; let plan = decodeOperationPlan(row.required(0))
    let canonical = match (decodeStoredThreadContent(row.required(6))) {
        case ThreadItemContent.ToolCall(id, name, arguments) => ToolCall(id.value, name, arguments)
        case _ => throw IllegalStateException("readonly ancestry has no canonical root call")
    }
    let provenance = decodeStoredProvenance(row.required(7))
    if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value) {
        throw IllegalStateException("readonly ancestry changed canonical Run provenance")
    }
    let parent = row.required(8); let root = row.required(9)
    let depth = Int64.parse(row.required(10)); let childCall = row.required(11)
    if (parent == "") {
        if (root != "" || depth != 0 || childCall != "" || row.required(12) != "" || row.required(13) != "") {
            throw IllegalStateException("canonical root cannot carry partial derived identity")
        }
    } else if (depth < 1 || depth > HOST_DERIVED_MAX_DEPTH || root == "" || childCall == "" ||
        row.required(12) == "" || row.required(13) != plan.bindingDigest || parent == operation.value || root == operation.value) {
        // In particular, migrated schema27 rows with empty call ID/depth0 can
        // never be used to reconstruct a deeper execution authority.
        throw IllegalStateException("readonly child has no exact host-minted derived identity")
    }
    ReadonlyDerivedNode(operation, parent, root, depth,
        if (parent == "") { canonical.callId } else { childCall }, row.required(12), plan,
        ItemId(row.required(1)), ThreadId(row.required(3)), SemanticTurnId(row.required(4)),
        Int64.parse(row.required(5)), canonical, provenance, row.required(2))
}

func readonlyDerivedParentHandoff(plan: NormalizedOperationPlan, epoch: Int64): AgentValue {
    let result = objectValue([
        ValueField(if (isFrozenReadonlyDelegationParentPlan(plan)) { "readonly_delegation_parent_epoch" }
            else { "read_view_parent_epoch" }, textValue(epoch.toString())),
        ValueField("parent_plan_digest", textValue(plan.bindingDigest))])
    if (isFrozenReadonlyDelegationParentPlan(plan)) {
        result.put("parent_plan_sha256", textValue(modelPolicySha256Text(encodeOperationPlan(plan))))
    }
    result
}

func readonlyDerivedHandoffId(transaction: SqliteTransaction, node: ReadonlyDerivedNode, run: RunId,
    settlementOnly!: Bool = false): String {
    let rows = transaction.query("SELECT id,payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? " +
        "AND kind='operation_execution_handoff'", [SqlParameter.Text(node.operation.value), SqlParameter.Text(run.value),
            SqlParameter.Text(node.thread.value)])
    if (rows.size != 1 || rows[0].required(1) != encodeStoredValue(readonlyDerivedParentHandoff(node.plan, node.epoch))) {
        throw IllegalStateException("readonly ancestor lost its unique exact current-epoch handoff")
    }
    let receipts = transaction.query("SELECT receipt.id,receipt.outcome,effect.reserved_receipt_id " +
        "FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id " +
        "WHERE receipt.operation_id=?", [SqlParameter.Text(node.operation.value)])
    if (node.state == "executing" && receipts.isEmpty()) { return rows[0].required(0) }
    // Cleanup may finish after an ancestor returned Unknown. This checks the
    // already executed, exact obligation; it never authorizes another handoff.
    // The same Run/epoch/active enclosure and full effect/state mirror were
    // checked by loadReadonlyDerivedNode in this transaction.
    if (!settlementOnly || node.state != "recovery_required" || receipts.size != 1 ||
        receipts[0].required(1) != "unknown" || receipts[0].required(0) != receipts[0].required(2)) {
        throw IllegalStateException("readonly ancestor is neither executing nor an exact Unknown cleanup obligation")
    }
    rows[0].required(0)
}

func readonlyDerivedEdgeAllowed(parent: ReadonlyDerivedNode, child: ReadonlyDerivedNode): Bool {
    if (parent.plan.toolName == child.plan.toolName || child.parent != parent.operation.value ||
        child.callId == parent.callId || child.depth != parent.depth + 1 ||
        child.root != (if (parent.parent == "") { parent.operation.value } else { parent.root }) ||
        child.item.value != parent.item.value || child.thread.value != parent.thread.value ||
        child.turn.value != parent.turn.value || child.epoch != parent.epoch) { return false }
    if (isFrozenReadonlyDelegationParentPlan(parent.plan)) {
        return parent.parent == "" && readonlyDelegationChildAllowed(parent.plan, child.plan) &&
            child.requestKey == readonlyDelegationRequestKey(parent.callId, child.callId)
    }
    // First rollout: an installed read-only contribution may consume only its
    // exact frozen read-view intent. HTTP/channel/file plans and recursive
    // delegate roots remain denied, regardless of a plugin's service string.
    isReadonlyDelegatedChildPlan(parent.plan) && isReadViewServiceChildPlan(child.plan) &&
        readViewServiceChildAllowed(parent.plan, child.plan) &&
        child.requestKey == exactServiceRequestKey(parent.callId, child.plan)
}

func readonlyDerivedEvidence(transaction: SqliteTransaction, run: RunId,
    ancestry: ReadonlyDerivedAncestry, child: ReadonlyDerivedNode): AgentValue {
    let root = ancestry.root; let chain = ArrayList<AgentValue>()
    for (node in ancestry.ancestors) {
        chain.add(objectValue([ValueField("operation_id", textValue(node.operation.value)),
            ValueField("call_id", textValue(node.callId)), ValueField("depth", integerValue(node.depth)),
            ValueField("parent_operation_id", textValue(node.parent)),
            ValueField("handoff_id", textValue(readonlyDerivedHandoffId(transaction, node, run, settlementOnly: ancestry.settlementOnly))),
            ValueField("plan_sha256", textValue(modelPolicySha256Text(encodeOperationPlan(node.plan))))]))
    }
    objectValue([ValueField("authorization_source", textValue("readonly_delegation")),
        ValueField("thread_id", textValue(root.thread.value)), ValueField("turn_id", textValue(root.turn.value)),
        ValueField("run_id", textValue(run.value)), ValueField("epoch", integerValue(root.epoch)),
        ValueField("root_operation_id", textValue(root.operation.value)), ValueField("root_item_id", textValue(root.item.value)),
        ValueField("root_call_id", textValue(root.callId)), ValueField("decision_id", textValue(ancestry.decisionId)),
        ValueField("scoped_tool_call_id", textValue(ancestry.scopedCallId)),
        ValueField("ancestry", listValue(chain.toArray())), ValueField("child_operation_id", textValue(child.operation.value)),
        ValueField("child_call_id", textValue(child.callId)), ValueField("depth", integerValue(child.depth)),
        ValueField("request_key", textValue(child.requestKey)),
        ValueField("child_plan_sha256", textValue(modelPolicySha256Text(encodeOperationPlan(child.plan))))])
}

func requireReadonlyDerivedAudit(transaction: SqliteTransaction, run: RunId,
    ancestry: ReadonlyDerivedAncestry, child: ReadonlyDerivedNode): Unit {
    let expected = encodeStoredValue(readonlyDerivedEvidence(transaction, run, ancestry, child))
    let rows = transaction.query("SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? " +
        "AND kind='operation_parent_intent_authorized'", [SqlParameter.Text(child.operation.value)])
    if (rows.size != 1 || rows[0].required(0) != ancestry.root.thread.value || rows[0].required(1) != run.value ||
        rows[0].required(2) != expected) {
        throw IllegalStateException("readonly tree's recorded canonical authorization changed")
    }
}

// Load every actual edge back to its canonical Item. `source` is checked only
// as the runtime's sealed attestation of these SQL facts; SQL does not mint it.
// Callers must perform source.validateLiveSource OUTSIDE this transaction.
func requireReadonlyDerivedAncestors(transaction: SqliteTransaction, parent: OperationId, run: RunId,
    source: ?OperationRootSource, allowCancelling!: Bool = false): ReadonlyDerivedAncestry {
    let reversed = ArrayList<ReadonlyDerivedNode>(); let seen = HashSet<String>()
    var current = parent
    while (true) {
        if (seen.contains(current.value) || reversed.size >= HOST_DERIVED_MAX_DEPTH) {
            throw IllegalStateException("readonly ancestry is cyclic or exceeds the hard depth bound")
        }
        seen.add(current.value)
        let node = loadReadonlyDerivedNode(transaction, current, run, allowCancelling)
        let _ = readonlyDerivedHandoffId(transaction, node, run, settlementOnly: allowCancelling)
        reversed.add(node)
        if (node.parent == "") { break }
        current = OperationId(node.parent)
    }
    let ordered = ArrayList<ReadonlyDerivedNode>()
    for (index in 0..reversed.size) { ordered.add(reversed[reversed.size - 1 - index]) }
    let root = ordered[0]
    // The canonical call may precede a trusted pre-tool hook. Its immutable
    // normalized plan and exact handoff freeze the effective input; the
    // original Item/source still proves the actual call identity.
    if (!isFrozenReadonlyDelegationParentPlan(root.plan) || root.plan.toolName != root.call.name) {
        throw IllegalStateException("readonly tree has no exact frozen canonical delegation root")
    }
    let decisions = transaction.query("SELECT d.id,b.scoped_tool_call_id FROM decision_operations source " +
        "JOIN model_decisions d ON d.id=source.decision_id JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
        "JOIN model_decision_blocks b ON b.decision_id=d.id AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
        "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
        "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? " +
        "AND b.kind='tool_call' AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
        [SqlParameter.Text(root.operation.value), SqlParameter.Text(root.item.value), SqlParameter.Text(run.value)])
    var decisionId = ""; var scopedCall = ""
    if (root.provenance.source == "direct_tool") {
        if (root.provenance.operationId.isNone() || root.provenance.operationId.getOrThrow().value != root.operation.value ||
            !decisions.isEmpty() || !transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
                [SqlParameter.Text(root.item.value)]).isEmpty()) {
            throw IllegalStateException("readonly direct root has ambiguous canonical source")
        }
    } else {
        if (decisions.size != 1 || root.provenance.operationId.isSome()) {
            throw IllegalStateException("readonly root has no unique validated committed Decision")
        }
        decisionId = decisions[0].required(0); scopedCall = decisions[0].required(1)
    }
    requireHostServiceOriginBinding(transaction, root.operation, run, root.item,
        allowCancellingSettlement: allowCancelling)
    match (source) {
        case Some(OperationRootSource.Committed(value)) =>
            if (value.decisionId.value != decisionId || value.scopedToolCallId.value != scopedCall ||
                value.canonicalItemId.value != root.item.value || value.block.callId != root.callId ||
                value.block.name != root.call.name || canonicalAgentValue(value.block.arguments) != canonicalAgentValue(root.call.arguments)) {
                throw IllegalStateException("readonly root differs from the actual committed source")
            }
        case Some(OperationRootSource.Direct(value)) =>
            if (decisionId != "" || value.operationId.value != root.operation.value || value.canonicalItemId.value != root.item.value ||
                value.runId.value != run.value || value.threadId.value != root.thread.value || value.turnId.value != root.turn.value ||
                value.epoch != root.epoch || value.call.callId != root.callId || value.call.name != root.call.name ||
                canonicalAgentValue(value.call.arguments) != canonicalAgentValue(root.call.arguments) ||
                !sameDirectCallOrigin(value.origin, effectiveDirectCallOrigin(root.provenance))) {
                throw IllegalStateException("readonly root differs from the actual Direct source")
            }
        case None => ()
    }
    let prefix = ArrayList<ReadonlyDerivedNode>([root])
    for (index in 1..ordered.size) {
        let child = ordered[index]
        if (!readonlyDerivedEdgeAllowed(prefix[prefix.size - 1], child) || child.depth != index) {
            throw IllegalStateException("readonly ancestry widened a frozen edge, scope, or host call identity")
        }
        requireReadonlyDerivedAudit(transaction, run, ReadonlyDerivedAncestry(prefix.toArray(), decisionId, scopedCall, settlementOnly: allowCancelling), child)
        prefix.add(child)
    }
    ReadonlyDerivedAncestry(prefix.toArray(), decisionId, scopedCall, settlementOnly: allowCancelling)
}

// Routing only. Any matching row must subsequently pass the complete actual
// ancestry proof; neither this predicate nor a root_operation_id is a grant.
func readonlyDerivedCandidateParent(transaction: SqliteTransaction, parent: OperationId, run: RunId): Bool {
    let rows = transaction.query("SELECT o.normalized_plan,a.operation_id FROM operations o " +
        "LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id WHERE o.id=? AND o.run_id=?",
        [SqlParameter.Text(parent.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { return false }
    let plan = decodeOperationPlan(rows[0].required(0))
    isFrozenReadonlyDelegationParentPlan(plan) || (rows[0][1].isSome() && isReadonlyDelegatedChildPlan(plan))
}

func readonlyDerivedProposedNode(ancestry: ReadonlyDerivedAncestry, operation: OperationId,
    callId: String, requestKey: String, plan: NormalizedOperationPlan): ReadonlyDerivedNode {
    let parent = ancestry.parent; let root = ancestry.root
    ReadonlyDerivedNode(operation, parent.operation.value, root.operation.value, parent.depth + 1,
        callId, requestKey, plan, root.item, root.thread, root.turn, root.epoch, root.call, root.provenance, "prepared")
}

func prepareReadonlyDerivedOperation(transaction: SqliteTransaction, operation: OperationId,
    parent: OperationId, run: RunId, source: OperationRootSource, requestKey: String,
    call: ToolCall, plan: NormalizedOperationPlan): OperationId {
    let ancestry = requireReadonlyDerivedAncestors(transaction, parent, run, Some(source))
    let root = ancestry.root
    let host = root.plan.canonicalArguments.field("host_plan").getOrThrow()
    let encoded = encodeOperationPlan(plan)
    let proposed = readonlyDerivedProposedNode(ancestry, operation, call.callId, requestKey, plan)
    if (!readonlyDerivedEdgeAllowed(ancestry.parent, proposed) ||
        proposed.depth > readonlyDelegationInteger(host, "max_depth") ||
        canonicalAgentValue(call.arguments) != canonicalAgentValue(plan.canonicalArguments) || call.name != plan.toolName) {
        throw IllegalStateException("readonly child differs from its exact approved ancestor capability ceiling")
    }
    let existing = transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=? AND request_key=?",
        [SqlParameter.Text(parent.value), SqlParameter.Text(requestKey)])
    if (!existing.isEmpty()) {
        if (existing.size != 1) { throw IllegalStateException("readonly request has ambiguous admission") }
        let previous = loadReadonlyDerivedNode(transaction, OperationId(existing[0].required(0)), run, false)
        if (previous.parent != parent.value || previous.root != root.operation.value || previous.depth != proposed.depth ||
            previous.callId != call.callId || previous.item.value != source.itemId().value ||
            previous.requestKey != requestKey || encodeOperationPlan(previous.plan) != encoded ||
            !readonlyDerivedEdgeAllowed(ancestry.parent, previous)) {
            throw IllegalStateException("readonly request identity is already bound to different canonical bytes")
        }
        requireReadonlyDerivedAudit(transaction, run, ancestry, previous)
        // Returning its existing identity is observation, never a second handoff.
        return previous.operation
    }
    if (!transaction.query("SELECT id FROM operations WHERE id=?", [SqlParameter.Text(operation.value)]).isEmpty() ||
        call.callId == root.callId || !transaction.query("SELECT operation_id FROM derived_operation_admissions " +
            "WHERE root_operation_id=? AND child_call_id=?", [SqlParameter.Text(root.operation.value),
                SqlParameter.Text(call.callId)]).isEmpty()) {
        throw IllegalStateException("readonly child repeats an Operation or host call identity")
    }
    let counts = transaction.query("SELECT " +
        "(SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id=?)," +
        "(SELECT COUNT(*) FROM derived_operation_admissions WHERE root_operation_id=?)",
        [SqlParameter.Text(parent.value), SqlParameter.Text(root.operation.value)])
    let width = Int64.parse(counts[0].required(0)); let total = Int64.parse(counts[0].required(1))
    if (width >= readonlyDelegationInteger(host, "max_calls") || width >= HOST_DERIVED_MAX_WIDTH ||
        total >= HOST_DERIVED_MAX_OPERATIONS) {
        throw IllegalStateException("readonly tree exhausted its immutable width or total admission budget")
    }
    let sequence = transaction.query("SELECT COALESCE(MAX(call_sequence),0)+1 FROM derived_operation_admissions " +
        "WHERE parent_operation_id=?", [SqlParameter.Text(parent.value)])
    let ordinal = Int64.parse(sequence[0].required(0))
    if (ordinal < 1) { throw IllegalStateException("readonly child sequence overflow") }
    transaction.execute("INSERT INTO operations " +
        "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) " +
        "VALUES (?,?,?,?,?,?,?,?,?,'prepared',1)", [SqlParameter.Text(operation.value), SqlParameter.Text(run.value),
            SqlParameter.Text(root.item.value), SqlParameter.Text(encoded), SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),
            SqlParameter.Text(encodeResourceScope(plan)), SqlParameter.Text(storeEffectName(plan.effectClass)),
            SqlParameter.Text(storeRetryName(plan.retryDisposition)),
            if (plan.idempotencyKey == "") { SqlParameter.Null } else { SqlParameter.Text(plan.idempotencyKey) }])
    insertOperationEffectRecord(transaction, operation, run, root.item, plan, encoded)
    transaction.execute("INSERT INTO derived_operation_admissions " +
        "(operation_id,parent_operation_id,call_sequence,request_key,request_digest,child_call_id,root_operation_id,depth) " +
        "VALUES (?,?,?,?,?,?,?,?)", [SqlParameter.Text(operation.value), SqlParameter.Text(parent.value),
            SqlParameter.Int64Value(ordinal), SqlParameter.Text(requestKey), SqlParameter.Text(plan.bindingDigest),
            SqlParameter.Text(call.callId), SqlParameter.Text(root.operation.value), SqlParameter.Int64Value(proposed.depth)])
    let evidence = readonlyDerivedEvidence(transaction, run, ancestry, proposed)
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES (?,?,?,'operation_parent_intent_authorized',?,?)", [SqlParameter.Text(root.thread.value),
            SqlParameter.Text(run.value), SqlParameter.Text(operation.value), SqlParameter.Text(encodeStoredValue(evidence)),
            SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())])
    operation
}

// None means this is an existing non-tree operation; malformed tree metadata
// throws instead of falling back to the old single-level permission path.
func requireReadonlyDerivedIntent(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, plan: NormalizedOperationPlan, allowCancelling: Bool): ?ReadonlyDerivedAncestry {
    let rows = transaction.query("SELECT parent_operation_id,depth FROM derived_operation_admissions WHERE operation_id=?",
        [SqlParameter.Text(operation.value)])
    if (rows.isEmpty()) { return None }
    if (rows.size != 1) { throw IllegalStateException("readonly ancestry has duplicate admission") }
    let parent = OperationId(rows[0].required(0))
    if (!readonlyDerivedCandidateParent(transaction, parent, run)) {
        if (Int64.parse(rows[0].required(1)) > 1) { throw IllegalStateException("nested source is outside the supported readonly tree") }
        return None
    }
    let ancestry = requireReadonlyDerivedAncestors(transaction, parent, run, None, allowCancelling: allowCancelling)
    let child = loadReadonlyDerivedNode(transaction, operation, run, allowCancelling)
    if (encodeOperationPlan(child.plan) != encodeOperationPlan(plan) || !readonlyDerivedEdgeAllowed(ancestry.parent, child)) {
        throw IllegalStateException("readonly executing child changed its full frozen plan or ancestor")
    }
    requireReadonlyDerivedAudit(transaction, run, ancestry, child)
    Some(ancestry)
}

func verifiedReadonlyOperationRoot(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, legacyRoot: OperationId): OperationId {
    let rows = transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("operation root lost its immutable plan") }
    match (requireReadonlyDerivedIntent(transaction, operation, run, decodeOperationPlan(rows[0].required(0)), false)) {
        case Some(ancestry) => ancestry.root.operation
        case None => legacyRoot
    }
}

// History decoding validates identity/edge structure but never reconstructs a
// current Runtime source, admits an operation, or grants an executor. Recovered
// descriptions still pass all current ancestry/ParentIntent checks at execute.
func requireReadonlyDerivedHistory(query: (String, Array<SqlParameter>) -> Array<SqliteRow>,
    operation: OperationId, run: RunId): OperationId {
    let reversed = ArrayList<ReadonlyDerivedNode>(); let seen = HashSet<String>()
    var current = operation
    while (true) {
        if (seen.contains(current.value) || reversed.size > HOST_DERIVED_MAX_DEPTH) {
            throw IllegalStateException("historical derived tree is cyclic or exceeds its bound")
        }
        seen.add(current.value)
        let rows = query("SELECT o.normalized_plan,o.tool_call_item_id,o.state,r.thread_id,r.turn_id,r.epoch,item.payload,item.provenance," +
            "COALESCE(a.parent_operation_id,''),COALESCE(a.root_operation_id,''),COALESCE(a.depth,0)," +
            "COALESCE(a.child_call_id,''),COALESCE(a.request_key,''),COALESCE(a.request_digest,'') " +
            "FROM operations o JOIN runs r ON r.id=o.run_id " +
            "JOIN items item ON item.id=o.tool_call_item_id AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
            "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=r.id " +
            "AND effect.tool_call_item_id=item.id AND effect.normalized_plan=o.normalized_plan " +
            "LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id WHERE o.id=? AND r.id=? AND item.kind='tool_call'",
            [SqlParameter.Text(current.value), SqlParameter.Text(run.value)])
        if (rows.size != 1) { throw IllegalStateException("historical child changed its canonical Run, Item, or effect plan") }
        let row = rows[0]; let plan = decodeOperationPlan(row.required(0))
        let call = match (decodeStoredThreadContent(row.required(6))) {
            case ThreadItemContent.ToolCall(id, name, arguments) => ToolCall(id.value, name, arguments)
            case _ => throw IllegalStateException("historical ancestry has no root ToolCall") }
        let parent = row.required(8); let root = row.required(9); let depth = Int64.parse(row.required(10))
        let childCall = row.required(11)
        if ((parent == "" && (root != "" || depth != 0 || childCall != "")) ||
            (parent != "" && (root == "" || childCall == "" || depth < 1 || depth > HOST_DERIVED_MAX_DEPTH ||
                row.required(12) == "" || row.required(13) != plan.bindingDigest))) {
            throw IllegalStateException("historical tree cannot infer missing or legacy derived identity")
        }
        let provenance = decodeStoredProvenance(row.required(7))
        if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value) {
            throw IllegalStateException("historical root call changed Run provenance")
        }
        reversed.add(ReadonlyDerivedNode(current, parent, root, depth, if (parent == "") { call.callId } else { childCall },
            row.required(12), plan, ItemId(row.required(1)), ThreadId(row.required(3)), SemanticTurnId(row.required(4)),
            Int64.parse(row.required(5)), call, provenance, row.required(2)))
        if (parent == "") { break }
        current = OperationId(parent)
    }
    let root = reversed[reversed.size - 1]
    if (!isFrozenReadonlyDelegationParentPlan(root.plan) || root.call.name != root.plan.toolName) {
        throw IllegalStateException("historical nested tree has no frozen readonly root")
    }
    let calls = HashSet<String>([root.callId])
    for (index in 0..(reversed.size - 1)) {
        let child = reversed[index]; let parent = reversed[index + 1]
        if (!readonlyDerivedEdgeAllowed(parent, child) || calls.contains(child.callId)) {
            throw IllegalStateException("historical nested tree changed a frozen edge or repeated a call identity")
        }
        calls.add(child.callId)
    }
    root.operation
}

// A known parent outcome must not wash a missing/Unknown descendant Receipt.
// Unknown keeps that debt visible and never permits an automatic replay.
func requireReadonlyDescendantsSettled(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, outcome: OperationOutcome): Unit {
    if (outcome == OperationOutcome.Unknown) { return }
    let pending = ArrayList<String>([operation.value]); let seen = HashSet<String>()
    var cursor: Int64 = 0
    while (cursor < pending.size) {
        let parent = pending[cursor]; cursor += 1
        if (seen.contains(parent) || seen.size > HOST_DERIVED_MAX_OPERATIONS) {
            throw IllegalStateException("derived settlement tree is cyclic or over budget")
        }
        seen.add(parent)
        let rows = transaction.query("SELECT a.operation_id,o.run_id,o.state,receipt.outcome,receipt.id," +
            "effect.reserved_receipt_id,o.tool_call_item_id,p.tool_call_item_id " +
            "FROM derived_operation_admissions a LEFT JOIN operations o ON o.id=a.operation_id " +
            "JOIN operations p ON p.id=a.parent_operation_id " +
            "LEFT JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.normalized_plan=o.normalized_plan " +
            "LEFT JOIN operation_receipts receipt ON receipt.operation_id=o.id WHERE a.parent_operation_id=?",
            [SqlParameter.Text(parent)])
        if (rows.size > HOST_DERIVED_MAX_WIDTH) { throw IllegalStateException("derived settlement width exceeds its bound") }
        for (row in rows) {
            if (row[1].isNone() || row.required(1) != run.value || row[3].isNone() || row[4].isNone() ||
                row[5].isNone() || row.required(4) != row.required(5) || row.required(6) != row.required(7) ||
                row.required(3) == "unknown" || (row.required(2) != "committed" && row.required(2) != "rejected" &&
                row.required(2) != "cancelled" && row.required(2) != "timed_out" && row.required(2) != "failed")) {
                throw IllegalStateException("known parent result cannot discard an unsettled or Unknown derived receipt")
            }
            pending.add(row.required(0))
        }
    }
}
