package agent_store

import yjson.*
import yjson_support.*

import agent_domain.*
import std.collection.*
import std.convert.*

// Historical evidence, never an execution/admission capability. Only this
// package can construct it; every consumer rechecks the same canonical rows in
// its own existing transaction. No live source or user owner is reconstructed.
public class CompletedPluginDocumentObservation {
    public let operationId: String
    public let receiptId: String
    public let runId: String
    public let epoch: Int64
    public let revision: Int64
    public let encoded: String
    public let digest: String
    public let expectedJson: String
    public let payload: ?PluginDocumentPayloadReference
    public let expectedPayload: ?PluginDocumentPayloadReference
    private let expectedDigest: String
    public let planDigest: String
    public let resultDigest: String
    private let frozenBinding: String
    init(operation: String, receipt: String, run: String, epoch: Int64, revision: Int64,
        encoded: String, binding: AgentValue, expectedJson: String, planDigest: String, resultDigest: String) {
        this.operationId = operation; this.receiptId = receipt; this.runId = run
        this.epoch = epoch; this.revision = revision; this.encoded = encoded
        this.digest = modelPolicySha256Text(encoded); this.frozenBinding = encodeStoredValue(binding)
        this.expectedJson = expectedJson; this.planDigest = planDigest; this.resultDigest = resultDigest
        this.expectedDigest = modelPolicySha256Text(expectedJson); this.payload = None; this.expectedPayload = None
    }
    init(operation: String, receipt: String, run: String, epoch: Int64, revision: Int64,
        payload: PluginDocumentPayloadReference, binding: AgentValue, expected: PluginDocumentPayloadReference,
        planDigest: String, resultDigest: String) {
        this.operationId = operation; this.receiptId = receipt; this.runId = run
        this.epoch = epoch; this.revision = revision; this.encoded = ""; this.expectedJson = ""
        this.digest = payload.digest; this.frozenBinding = encodeStoredValue(binding)
        this.expectedDigest = expected.digest; this.payload = Some(payload); this.expectedPayload = Some(expected)
        this.planDigest = planDigest; this.resultDigest = resultDigest
    }
    public func binding(): AgentValue { decodeStoredValue(frozenBinding) }
    public func descriptor(): AgentValue {
        objectValue([ValueField("operation_id", textValue(operationId)), ValueField("receipt_id", textValue(receiptId)),
            ValueField("run_id", textValue(runId)), ValueField("epoch", integerValue(epoch)), ValueField("revision", integerValue(revision)),
            ValueField("expected_sha256", textValue(expectedDigest)), ValueField("document_sha256", textValue(digest)),
            ValueField("plan_sha256", textValue(planDigest)), ValueField("result_sha256", textValue(resultDigest))])
    }
}

// Observes only an actual completed root Tool -> document CAS in a completed
// Run. A repository write, imported row, readonly Receipt, plugin claim, failed
// root or unfinished Run is not a mutation witness. It confers no read grant;
// Product must retain the original operator scope before calling this method.
public func observeCompletedPluginDocument(transaction: SqliteTransaction, snapshot: PluginDocumentSnapshot,
    parentTool: String, packageDigest: String, generation: String, configurationDigest: String,
    scope!: ContinuationDocumentReadScope, operationId!: ?String = None): Result<CompletedPluginDocumentObservation> {
    try {
        if (snapshot.revision < 1 || snapshot.encoded.size > PLUGIN_DOCUMENT_MAX_BYTES) {
            return continuationDocumentObservationError() }
        let result = encodeStoredValue(objectValue([
            ValueField("schema", textValue("axyndra.plugin-document-result/v1")),
            ValueField("key", textValue(snapshot.key)), ValueField("revision", integerValue(snapshot.revision)),
            ValueField("json", textValue(snapshot.encoded))]))
        let rows = scope.query(transaction, "SELECT child.id,receipt.id,r.id,r.epoch,parent.id,parent.normalized_plan," +
            "child.normalized_plan,i.id,i.payload,i.provenance,a.request_key,ph.id,ph.payload,r.turn_id,a.request_digest," +
            "parent_result.payload,pr.id,pr.detail " +
            "FROM operation_receipts receipt JOIN operations child ON child.id=receipt.operation_id " +
            "JOIN derived_operation_admissions a ON a.operation_id=child.id " +
            "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=child.run_id " +
            "AND parent.tool_call_item_id=child.tool_call_item_id " +
            "JOIN runs r ON r.id=child.run_id JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id " +
            "JOIN items i ON i.id=parent.tool_call_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id " +
            "JOIN run_lane_bindings lane ON lane.run_id=r.id AND lane.thread_id=r.thread_id " +
            "JOIN item_tree_edges edge ON edge.item_id=i.id AND edge.thread_id=r.thread_id AND edge.lane_id=lane.lane_id " +
            "JOIN operation_effect_records pe ON pe.operation_id=parent.id AND pe.run_id=r.id AND pe.tool_call_item_id=i.id " +
            "AND pe.normalized_plan=parent.normalized_plan " +
            "JOIN operation_effect_records ce ON ce.operation_id=child.id AND ce.run_id=r.id AND ce.tool_call_item_id=i.id " +
            "AND ce.normalized_plan=child.normalized_plan AND ce.reserved_receipt_id=receipt.id " +
            "JOIN operation_state_registers ps ON ps.operation_id=parent.id AND ps.state=parent.state " +
            "JOIN operation_state_registers cs ON cs.operation_id=child.id AND cs.state=child.state " +
            "JOIN operation_receipts pr ON pr.operation_id=parent.id AND pr.id=pe.reserved_receipt_id AND pr.outcome='completed' " +
            "JOIN items parent_result ON parent_result.id=pe.reserved_result_item_id AND parent_result.thread_id=r.thread_id " +
            "AND parent_result.turn_id=r.turn_id AND parent_result.kind='tool_result' " +
            "JOIN audit_events ph ON ph.operation_id=parent.id AND ph.run_id=r.id AND ph.thread_id=r.thread_id " +
            "AND ph.kind='operation_execution_handoff' " +
            "WHERE r.thread_id=? AND lane.lane_id=? AND pe.tool_id=? AND receipt.detail=? AND receipt.outcome='completed' " +
            "AND r.state='completed' AND t.state='completed' AND t.active_run_id IS NULL AND i.kind='tool_call' " +
            "AND child.state='committed' AND parent.state='committed' " +
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions nested WHERE nested.operation_id=parent.id) " +
            "AND (?='' OR child.id=?) LIMIT 2",
            [SqlParameter.Text(snapshot.threadId.value), SqlParameter.Text(snapshot.laneId.value), SqlParameter.Text(parentTool),
                SqlParameter.Text(result), SqlParameter.Text(operationId ?? ""), SqlParameter.Text(operationId ?? "")], 18)
        if (rows.size != 1) { return continuationDocumentObservationError() }
        let row = rows[0]
        for (index in [5, 6, 8, 9, 15, 17]) { scope.preflightStored(row.required(index)) }
        let parent = decodeOperationPlan(row.required(5)); let child = decodeOperationPlan(row.required(6))
        if (parent.toolName != parentTool || !pluginDocumentParentAllows(parent, child) || row.required(14) != child.bindingDigest) {
            return continuationDocumentObservationError() }
        let intent = parsePluginDocumentIntent(child.canonicalArguments).value().getOrThrow()
        let binding = intent.binding()
        if (!intent.compareExchange || intent.expectedRevision != snapshot.revision - 1 ||
            intent.key != snapshot.key || intent.nextJson.getOrThrow() != snapshot.encoded ||
            httpIntentText(binding, "thread_id") != snapshot.threadId.value ||
            httpIntentText(binding, "lane_id") != snapshot.laneId.value ||
            httpIntentText(binding, "namespace") != snapshot.namespace ||
            httpIntentText(binding, "package_digest") != packageDigest || httpIntentText(binding, "generation") != generation ||
            httpIntentText(binding, "configuration_digest") != configurationDigest ||
            httpIntentText(binding, "run_id") != row.required(2) ||
            binding.field("epoch").getOrThrow().asNumberText() != row.required(3)) { return continuationDocumentObservationError() }
        let callId = match (decodeStoredThreadContent(row.required(8))) {
            case ThreadItemContent.ToolCall(id, name, input) =>
                if (name != parentTool || id.value != httpIntentText(binding, "parent_call_id") ||
                    canonicalAgentValue(input) != canonicalAgentValue(contextReadBusinessInput(parent.canonicalArguments.field("input").getOrThrow()))) {
                    return continuationDocumentObservationError() }
                id.value
            case _ => return continuationDocumentObservationError() }
        match (decodeStoredThreadContent(row.required(15))) {
            case ThreadItemContent.ToolResult(id, operation, receipt, output, isError) =>
                if (id.value != callId || operation.value != row.required(4) || receipt != row.required(16) || isError ||
                    canonicalAgentValue(output) != canonicalAgentValue(decodeStoredValue(row.required(17)))) {
                    return continuationDocumentObservationError() }
            case _ => return continuationDocumentObservationError()
        }
        if (row.required(10) != exactServiceRequestKey(callId, child) || row.required(12) != encodeStoredValue(objectValue([
            ValueField("document_parent_epoch", textValue(row.required(3))),
            ValueField("parent_plan_digest", textValue(modelPolicySha256Text(row.required(5))))]))) {
            return continuationDocumentObservationError() }
        let provenance = decodeStoredProvenance(row.required(9))
        if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != row.required(2)) {
            return continuationDocumentObservationError() }
        for (link in parent.contextReadFacts) {
            // Pay for the original fact loader's enclosure before its codec
            // constructs values; this remains a read of canonical old facts.
            let factBytes = scope.query(transaction, "SELECT call.payload,call.provenance,o.normalized_plan,receipt.detail,result.payload,a.payload " +
                "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN items call ON call.id=o.tool_call_item_id JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
                "JOIN items result ON result.id=e.reserved_result_item_id JOIN audit_events a ON a.operation_id=o.id " +
                "AND a.kind='context_read_admitted' WHERE o.id=? AND o.run_id=?",
                [SqlParameter.Text(link.operationId.value), SqlParameter.Text(row.required(2))], 6)
            if (factBytes.size != 1) { return continuationDocumentObservationError() }
            for (index in 0..6) { scope.preflightStored(factBytes[0].required(index)) }
            let fact = requireContextReadFact(transaction, link.operationId, RunId(row.required(2)))
            if (link.runId.value != row.required(2) || fact.origin.parentCallItemId != row.required(7) ||
                canonicalAgentValue(link.toValue()) != canonicalAgentValue(fact.reference())) {
                return continuationDocumentObservationError() }
        }
        let decisions = scope.query(transaction, "SELECT d.id,b.scoped_tool_call_id FROM decision_operations source " +
            "JOIN model_decisions d ON d.id=source.decision_id JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
            "JOIN model_decision_blocks b ON b.decision_id=d.id AND b.scoped_tool_call_id=source.scoped_tool_call_id AND b.kind='tool_call' " +
            "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
            "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? AND d.validation_status='validated' " +
            "AND d.canonical_committed_at_millis IS NOT NULL", [SqlParameter.Text(row.required(4)),
                SqlParameter.Text(row.required(7)), SqlParameter.Text(row.required(2))], 2)
        let direct = provenance.source == "direct_tool"
        if (direct) {
            if (provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != row.required(4) ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect) || !decisions.isEmpty() ||
                !scope.query(transaction, "SELECT decision_id FROM decision_operations WHERE operation_id=?", [SqlParameter.Text(row.required(4))], 1).isEmpty() ||
                !scope.query(transaction, "SELECT decision_id FROM canonical_decision_items WHERE item_id=?", [SqlParameter.Text(row.required(7))], 1).isEmpty()) {
                return continuationDocumentObservationError() }
        } else if (decisions.size != 1 || provenance.operationId.isSome()) { return continuationDocumentObservationError() }
        let evidence = objectValue([
            ValueField("authorization_source", textValue("parent_intent")), ValueField("root_source", textValue(if (direct) { "direct" } else { "committed" })),
            ValueField("thread_id", textValue(snapshot.threadId.value)), ValueField("turn_id", textValue(row.required(13))),
            ValueField("run_id", textValue(row.required(2))), ValueField("epoch", textValue(row.required(3))),
            ValueField("root_item_id", textValue(row.required(7))), ValueField("root_call_id", textValue(callId)),
            ValueField("decision_id", textValue(if (direct) { "" } else { decisions[0].required(0) })),
            ValueField("scoped_tool_call_id", textValue(if (direct) { "" } else { decisions[0].required(1) })),
            ValueField("parent_operation_id", textValue(row.required(4))), ValueField("parent_handoff_id", textValue(row.required(11))),
            ValueField("parent_plan_digest", textValue(parent.bindingDigest)), ValueField("child_operation_id", textValue(row.required(0))),
            ValueField("child_plan_digest", textValue(child.bindingDigest)), ValueField("request_key", textValue(row.required(10))),
            ValueField("intent_id", textValue(intent.id)), ValueField("document_intent_digest", textValue(modelPolicySha256Text(row.required(6))))])
        match (provenance.directOrigin) { case Some(value) => evidence.put("root_origin", directCallOriginValue(value)); case None => () }
        let authorized = scope.query(transaction, "SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind='operation_parent_intent_authorized'",
            [SqlParameter.Text(row.required(0))], 3)
        let handed = scope.query(transaction, "SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(row.required(0)), SqlParameter.Text(row.required(2)), SqlParameter.Text(snapshot.threadId.value)], 1)
        if (authorized.size != 1 || authorized[0].required(0) != snapshot.threadId.value || authorized[0].required(1) != row.required(2) ||
            authorized[0].required(2) != encodeStoredValue(evidence) || handed.size != 1) { return continuationDocumentObservationError() }
        Result.Ok(CompletedPluginDocumentObservation(row.required(0), row.required(1), row.required(2),
            Int64.parse(row.required(3)), snapshot.revision, snapshot.encoded, binding, intent.expectedJson,
            modelPolicySha256Text(row.required(6)), modelPolicySha256Text(result)))
    } catch (_: Exception) { continuationDocumentObservationError() }
}

// Walk exact CAS predecessors, not an arbitrary audit scan. The full chain is
// bounded by count and aggregate raw bytes. Gaps, ambiguous receipts and a
// repository-only replacement are all closed. The original user document is
// included, so every pure call receives the same immutable approval premise.
public func observeContinuationDocumentChain(transaction: SqliteTransaction, snapshot: PluginDocumentSnapshot,
    originalOperation: String, originalRevision: Int64, originalDigest: String,
    parentTool: String, packageDigest: String, generation: String, configurationDigest: String, scope!: ContinuationDocumentReadScope): Result<Array<CompletedPluginDocumentObservation>> {
    try {
        if (originalRevision < 1 || snapshot.revision < originalRevision || snapshot.revision - originalRevision >= 256) {
            return continuationDocumentObservationError() }
        let reverse = ArrayList<CompletedPluginDocumentObservation>()
        var current = snapshot
        var bytes: Int64 = 0
        while (true) {
            if (bytes > 8388608 - current.encoded.size) { return continuationDocumentObservationError() }
            bytes += current.encoded.size
            let actual = match (observeCompletedPluginDocument(transaction, current, parentTool, packageDigest, generation, configurationDigest, scope: scope)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            reverse.add(actual)
            if (actual.revision == originalRevision) {
                if (actual.operationId != originalOperation || actual.digest != originalDigest) { return continuationDocumentObservationError() }
                break
            }
            current = PluginDocumentSnapshot(snapshot.threadId, snapshot.laneId, snapshot.namespace, snapshot.key,
                actual.revision - 1, actual.expectedJson)
        }
        Result.Ok(Array<CompletedPluginDocumentObservation>(reverse.size, { index => reverse[reverse.size - 1 - index] }))
    } catch (_: Exception) { continuationDocumentObservationError() }
}

public func verifyContinuationDocumentObservation(transaction: SqliteTransaction, thread: ThreadId, lane: LaneId,
    namespace: String, key: String, ownerDigest: String, observation: ContinuationDocumentObservation, scope!: ContinuationDocumentReadScope): Result<Unit> {
    try {
        let value = observation.value()
        if (httpIntentText(value, "owner_digest") != ownerDigest) { return continuationDocumentObservationError() }
        let version = match (readContinuationDocumentVersion(transaction, thread, lane, namespace, key, scope)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(actual) => actual }
        if (version.revision.toString() != value.field("document_revision").getOrThrow().asNumberText() ||
            version.payload.digest != httpIntentText(value, "document_sha256")) { return continuationDocumentObservationError() }
        let originalRows = scope.query(transaction, "SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(httpIntentText(value, "original_operation_id"))], 1)
        if (originalRows.size != 1) { return continuationDocumentObservationError() }
        scope.preflightStored(originalRows[0].required(0))
        let originalIntent = parsePluginDocumentIntent(decodeOperationPlan(originalRows[0].required(0)).canonicalArguments).value().getOrThrow()
        let originalRevision = Int64.parse(value.field("original_revision").getOrThrow().asNumberText())
        let originalResult: Result<CompletedPluginDocumentObservation> = if (originalIntent.referencesPayload) {
            observeCompletedPluginDocumentPayload(transaction, ContinuationDocumentVersion(thread, lane, namespace, key,
                originalRevision, originalIntent.nextPayload.getOrThrow()), httpIntentText(value, "parent_tool"),
                httpIntentText(value, "package_digest"), httpIntentText(value, "provider_generation"),
                httpIntentText(value, "configuration_digest"), scope, operationId: Some(httpIntentText(value, "original_operation_id")))
        } else {
            observeCompletedPluginDocument(transaction, PluginDocumentSnapshot(thread, lane, namespace, key,
                originalRevision, originalIntent.nextJson.getOrThrow()), httpIntentText(value, "parent_tool"),
                httpIntentText(value, "package_digest"), httpIntentText(value, "provider_generation"),
                httpIntentText(value, "configuration_digest"), scope: scope, operationId: Some(httpIntentText(value, "original_operation_id")))
        }
        let original = match (originalResult) { case Result.Err(error) => return Result.Err(error); case Result.Ok(actual) => actual }
        if (original.receiptId != httpIntentText(value, "original_receipt_id") || original.runId != httpIntentText(value, "original_run_id") ||
            original.digest != httpIntentText(value, "original_document_sha256") ||
            original.epoch.toString() != value.field("original_epoch").getOrThrow().asNumberText()) { return continuationDocumentObservationError() }
        let anchorRun = httpIntentText(value, "anchor_run_id")
        if (anchorRun != "") {
            let anchors = scope.query(transaction, "SELECT a.payload,r.epoch FROM audit_events a " +
                "JOIN runs r ON r.id=a.run_id AND r.thread_id=a.thread_id JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id " +
                "JOIN run_lane_bindings lane ON lane.run_id=r.id AND lane.thread_id=r.thread_id " +
                "WHERE a.thread_id=? AND a.run_id=? AND a.kind='host_continuation_claim_consumed_v1' " +
                "AND lane.lane_id=? AND r.state='completed' AND t.state='completed' AND t.active_run_id IS NULL",
                [SqlParameter.Text(thread.value), SqlParameter.Text(anchorRun), SqlParameter.Text(lane.value)], 2)
            if (anchors.size != 1 || modelPolicySha256Text(anchors[0].required(0)) != httpIntentText(value, "anchor_claim_sha256")) {
                return continuationDocumentObservationError() }
            scope.preflightStored(anchors[0].required(0))
            let prior = continuationRunOriginFromValue(decodeStoredValue(anchors[0].required(0)).field("origin").getOrThrow())
            if (prior.threadId != thread.value || prior.laneId != lane.value || prior.namespace != namespace || prior.documentKey != key ||
                prior.runId != anchorRun || prior.epoch.toString() != anchors[0].required(1) || prior.controlSourceDigest != ownerDigest ||
                prior.documentObservation.isNone()) { return continuationDocumentObservationError() }
            let end = prior.documentObservation.getOrThrow().value()
            for ((currentName, priorName) in [("anchor_operation_id", "document_operation_id"), ("anchor_revision", "document_revision"),
                ("anchor_document_sha256", "document_sha256"), ("original_operation_id", "original_operation_id"),
                ("original_document_sha256", "original_document_sha256"), ("package_digest", "package_digest"),
                ("provider", "provider"), ("provider_generation", "provider_generation"), ("selector_sha256", "selector_sha256"),
                ("configuration_digest", "configuration_digest"), ("parent_tool", "parent_tool")]) {
                if (canonicalAgentValue(value.field(currentName).getOrThrow()) != canonicalAgentValue(end.field(priorName).getOrThrow())) {
                    return continuationDocumentObservationError() }
            }
        }
        let chainResult: Result<Array<CompletedPluginDocumentObservation>> = if (originalIntent.referencesPayload) {
            observeContinuationDocumentPayloadChain(transaction, version, httpIntentText(value, "anchor_operation_id"),
                Int64.parse(value.field("anchor_revision").getOrThrow().asNumberText()), httpIntentText(value, "anchor_document_sha256"),
                httpIntentText(value, "parent_tool"), httpIntentText(value, "package_digest"), httpIntentText(value, "provider_generation"),
                httpIntentText(value, "configuration_digest"), scope)
        } else {
            // Inline v1 keeps its original paid raw chain; v2 never enters
            // this materialization path during final admission validation.
            let docs = scope.query(transaction, "SELECT payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                [SqlParameter.Text(thread.value), SqlParameter.Text(lane.value), SqlParameter.Text(namespace), SqlParameter.Text(key)], 1)
            if (docs.size != 1) { return continuationDocumentObservationError() }
            observeContinuationDocumentChain(transaction, PluginDocumentSnapshot(thread, lane, namespace, key, version.revision, docs[0].required(0)),
                httpIntentText(value, "anchor_operation_id"), Int64.parse(value.field("anchor_revision").getOrThrow().asNumberText()),
                httpIntentText(value, "anchor_document_sha256"), httpIntentText(value, "parent_tool"), httpIntentText(value, "package_digest"),
                httpIntentText(value, "provider_generation"), httpIntentText(value, "configuration_digest"), scope: scope)
        }
        let chain = match (chainResult) { case Result.Err(error) => return Result.Err(error); case Result.Ok(actual) => actual }
        let frozen = value.field("chain").getOrThrow().items
        if (chain.size != frozen.size) { return continuationDocumentObservationError() }
        let expectedReply = modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("continue", boolValue(true))])))
        if (httpIntentText(value, "query_sha256") != modelPolicySha256Text(canonicalAgentValue(value.field("chain").getOrThrow())) ||
            httpIntentText(value, "reply_sha256") != expectedReply) { return continuationDocumentObservationError() }
        for (index in 0..chain.size) {
            if (canonicalAgentValue(chain[index].descriptor()) != canonicalAgentValue(frozen[index].field("mutation").getOrThrow()) ||
                httpIntentText(frozen[index], "reply_sha256") != expectedReply) {
                return continuationDocumentObservationError() }
        }
        let last = chain[chain.size - 1]
        if (last.operationId != httpIntentText(value, "document_operation_id") || last.receiptId != httpIntentText(value, "document_receipt_id") ||
            last.runId != httpIntentText(value, "document_run_id") || last.epoch.toString() != value.field("document_epoch").getOrThrow().asNumberText()) {
            return continuationDocumentObservationError() }
        Result.Ok(())
    } catch (_: Exception) { continuationDocumentObservationError() }
}

func continuationDocumentObservationError<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "continuation.document_observation_invalid",
        "continuation requires an exact completed canonical document mutation"))
}
