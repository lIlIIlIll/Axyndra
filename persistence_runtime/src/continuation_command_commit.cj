package persistence_runtime

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*

// The only consumer of this object is an actual private document-commit proof.
// Its constructor data does not mint a user scope or a future Run authority.
// Product's nonserializable user owner supplies it; reopening facts cannot.
public class SqliteContinuationCommandParticipant <: PluginDocumentCommitParticipant {
    private let facts: ContinuationAllowanceRepository
    private let address: ContinuationAllowanceAddress
    private let expected: ?ContinuationAllowanceFacts
    private let control: ContinuationAllowanceControl
    private let sourceDigest: String
    private let run: RunId
    private let epoch: Int64
    private let callId: String
    private let toolName: String
    private let arguments: String
    private let packageDigest: String
    private let generation: String
    private let cancellation: CancellationToken
    private let expectedParentArguments: ?String

    public init(facts: ContinuationAllowanceRepository, address: ContinuationAllowanceAddress,
        expected: ?ContinuationAllowanceFacts, control: ContinuationAllowanceControl, sourceDigest: String,
        run: RunId, epoch: Int64, call: ToolCall, packageDigest: String, generation: UInt64,
        cancellation: CancellationToken, expectedParentArguments!: ?String = None) {
        this.facts = facts; this.address = address; this.expected = expected; this.control = control
        this.sourceDigest = sourceDigest; this.run = run; this.epoch = epoch
        this.callId = call.callId; this.toolName = call.name; this.arguments = canonicalAgentValue(call.arguments)
        this.packageDigest = packageDigest; this.generation = generation.toString(); this.cancellation = cancellation
        this.expectedParentArguments = expectedParentArguments
    }
    public func consume(proof: PluginDocumentCommitProof): Result<Unit> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let actual = match (proof as SqlitePluginDocumentCommitProof) {
            case Some(value) => value
            case None => return allowanceError("continuation.document_proof_required", AgentErrorKind.PermissionDenied) }
        if (proof.runId.value != run.value || proof.receipt().outcome != OperationOutcome.Completed ||
            !isPluginDocumentChildPlan(proof.plan())) {
            return allowanceError("continuation.document_control_mismatch", AgentErrorKind.PermissionDenied) }
        let intent = parsePluginDocumentIntent(proof.plan().canonicalArguments).value().getOrThrow()
        let binding = intent.binding()
        if (!intent.compareExchange || intent.key != address.documentKey ||
            httpIntentText(binding, "thread_id") != address.threadId.value || httpIntentText(binding, "lane_id") != address.laneId.value ||
            httpIntentText(binding, "namespace") != address.namespace || httpIntentText(binding, "package_digest") != packageDigest ||
            httpIntentText(binding, "generation") != generation || httpIntentText(binding, "run_id") != run.value ||
            binding.field("epoch").getOrThrow().asNumberText() != epoch.toString() ||
            httpIntentText(binding, "parent_call_id") != callId || httpIntentText(binding, "contribution") != toolName) {
            return allowanceError("continuation.document_control_mismatch", AgentErrorKind.PermissionDenied) }
        return actual.withTransaction({ tx =>
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let rows = tx.query("SELECT i.payload,i.provenance,r.epoch,r.state,e.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN items i ON i.id=o.tool_call_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id " +
                "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id AND t.active_run_id=r.id AND t.state='active' " +
                "JOIN threads owner ON owner.id=r.thread_id AND owner.active_turn_id=r.turn_id " +
                "WHERE o.id=? AND o.run_id=? AND r.thread_id=? AND i.kind='tool_call' AND o.state='executing'",
                [SqlParameter.Text(proof.parentOperationId.value), SqlParameter.Text(run.value), SqlParameter.Text(address.threadId.value)])
            if (rows.size != 1 || rows[0].required(2) != epoch.toString() || rows[0].required(3) != "running") {
                return allowanceError("continuation.user_parent_inactive", AgentErrorKind.PermissionDenied) }
            let provenance = decodeStoredProvenance(rows[0].required(1))
            if (provenance.source != "direct_tool" || provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
                provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != proof.parentOperationId.value ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect)) {
                return allowanceError("continuation.actual_user_parent_required", AgentErrorKind.PermissionDenied) }
            match (decodeStoredThreadContent(rows[0].required(0))) {
                case ThreadItemContent.ToolCall(id, name, input) => if (id.value != callId || name != toolName || canonicalAgentValue(input) != arguments) {
                    return allowanceError("continuation.user_call_changed", AgentErrorKind.PermissionDenied) }
                case _ => return allowanceError("continuation.actual_user_parent_required", AgentErrorKind.PermissionDenied) }
            match (expectedParentArguments) { case Some(frozen) =>
                if (!storedOperationArgumentsMatch(rows[0].required(4), frozen)) {
                    return allowanceError("continuation.user_plan_changed", AgentErrorKind.PermissionDenied) }
                case None => () }
            // No callback to Product/Runtime or second DB transaction while
            // this actual Store transaction and proof window are held.
            let next = match (facts.appendControlFacts(tx, address, expected, control, sourceDigest, proof.receipt().observedAtMillis)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES (?,?,?,?,?,?,0)",
                [SqlParameter.Text(address.threadId.value), SqlParameter.Text(run.value), SqlParameter.Text(proof.operationId.value),
                    SqlParameter.Text("host_continuation_control_document_v1"), SqlParameter.Text(encodeStoredValue(objectValue([
                        ValueField("control_event_id", integerValue(next.eventId)), ValueField("source_digest", textValue(sourceDigest)),
                        ValueField("lane_id", textValue(address.laneId.value)), ValueField("namespace", textValue(address.namespace)),
                        ValueField("document_key", textValue(address.documentKey)), ValueField("revision", integerValue(intent.expectedRevision + 1)),
                        ValueField("sha256", textValue(if (intent.referencesPayload) { intent.nextPayload.getOrThrow().digest } else { modelPolicySha256Text(intent.nextJson.getOrThrow()) }))]))),
                    SqlParameter.Int64Value(proof.receipt().observedAtMillis)])
            cancellation.check()
        })
    }
}
