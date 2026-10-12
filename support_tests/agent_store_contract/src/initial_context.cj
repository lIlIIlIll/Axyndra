package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

func initialStoreRequest(f: ModelLaneCutFixture): AgentValue {
    let active = f.runtime.activeRun().getOrThrow()
    objectValue([ValueField("schema", textValue("axyndra.accepted-context-request/v1")),
        ValueField("run_id", textValue(f.run.value)), ValueField("session_id", textValue(f.thread.value)),
        ValueField("epoch", integerValue(active.epoch)), ValueField("model", textValue(active.lane.modelId)),
        ValueField("prompt", textValue("refresh catalog")), ValueField("system", textValue("initial system")),
        ValueField("skill_stack", contextSnapshotValue(active.contextSnapshot)), ValueField("lane_id", textValue("main")),
        ValueField("budget", decodeStoredValue(f.database.query("SELECT budget FROM runs")[0].required(0))),
        ValueField("tool_context", objectValue([])), ValueField("capabilities", listValue([]))])
}
func initialStoreField(value: AgentValue, key: String, replacement: AgentValue): AgentValue {
    let fields = ArrayList<ValueField>()
    for (field in value.fields) { fields.add(if (field.name == key) { ValueField(key, replacement) } else { field }) }
    objectValue(fields.toArray())
}
func initialStoreBind(f: ModelLaneCutFixture, value: AgentValue,
    run!: RunId = RunId("cut-run"), thread!: SessionId = SessionId("cut-thread"), epoch!: Int64 = 1,
    input!: ThreadItemContent = ThreadItemContent.UserMessage(textMessageParts("refresh catalog")),
    observedAt!: Int64 = 30): Bool {
    try {
        f.database.transaction { tx => bindAcceptedContextRequestInTransaction(tx, run, thread, epoch, input, value, observedAt) }
        true
    } catch (_: Exception) { false }
}

func initialContextStoreContracts(): Unit {
    let f = ModelLaneCutFixture()
    try {
        let original = f.continuation()
        let request = initialStoreRequest(f)
        let epoch = f.runtime.activeRun().getOrThrow().epoch
        expect(initialStoreBind(f, request, epoch: epoch), "Accepted data binds only to the actual running user turn")
        let bound = f.continuation()
        let revision = f.database.scalarInt("SELECT revision FROM run_continuations")
        expect(bound.modelLaneSnapshotId.value == original.modelLaneSnapshotId.value &&
            bound.compositionSnapshotId.value == original.compositionSnapshotId.value &&
            encodeStoredValue(optionalRunRequestSnapshotFromDurableContinuation(bound).getOrThrow()) == encodeStoredValue(request) &&
            f.database.scalarInt("SELECT COUNT(*) FROM operations") == 0 &&
            f.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 &&
            f.database.scalarInt("SELECT COUNT(*) FROM items") == 1,
            "the diagnostic projection creates no effect, model Attempt, fake approval or extra initiator")
        expect(initialStoreBind(f, request, epoch: epoch) && f.continuation().digest == bound.digest &&
            f.database.scalarInt("SELECT revision FROM run_continuations") == revision &&
            f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='initial_context_request_bound'") == 1,
            "identical Accepted data is idempotent without another revision or audit")
        expect(!initialStoreBind(f, initialStoreField(request, "system", textValue("changed")), epoch: epoch) &&
            f.continuation().digest == bound.digest, "a primitive Run id cannot replace the initial request")
        let next = InvocationContextProjection(contributions: [InvocationContextContribution("host", "observed", "host:observed", "frozen content",
            ContextContentTrust.UntrustedData)])
        f.runtime.queueContextSnapshot(f.run, epoch, contextReadProjectionDigest(InvocationContextProjection()), next).value().getOrThrow()
        expect(f.runtime.applyContextSnapshotAtSafeCut(f.run, epoch).isOk(), "the same existing model-lane CAS accepts a seeded request")
        let after = f.continuation()
        let projected = optionalRunRequestSnapshotFromDurableContinuation(after).getOrThrow()
        expect(encodeStoredValue(projected.field("skill_stack").getOrThrow()) == encodeStoredValue(contextSnapshotValue(next)) &&
            httpIntentText(projected, "prompt") == "refresh catalog" && after.attemptId.isNone() &&
            f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1,
            "initial context changes preserve request data and use the existing persisted composition cut")
        expect(!initialStoreBind(f, request, epoch: epoch) && f.continuation().digest == after.digest,
            "the Accepted-only binding cannot overwrite a later canonical context checkpoint")
    } finally { f.close() }
    initialContextStoreRollback()
    for (scenario in ["schema", "unknown-field", "system-type", "capability-shape", "run", "thread", "epoch", "model",
        "prompt", "user-item", "budget", "projection", "lane", "before-start", "cancelled", "pending-call", "work-debt", "phase"]) {
        initialContextStoreFence(scenario)
    }
    println("Store initial context request contract passed (persistence, rollback, 18 fences)")
}

func initialContextStoreRollback(): Unit {
    let f = ModelLaneCutFixture()
    try {
        let request = initialStoreRequest(f); let before = f.continuation().digest
        let revision = f.database.scalarInt("SELECT revision FROM run_continuations")
        f.database.execute("CREATE TRIGGER reject_initial_context_audit BEFORE INSERT ON audit_events " +
            "WHEN NEW.kind='initial_context_request_bound' BEGIN SELECT RAISE(ABORT,'initial fault'); END")
        expect(!initialStoreBind(f, request, epoch: f.runtime.activeRun().getOrThrow().epoch) &&
            f.continuation().digest == before && f.database.scalarInt("SELECT revision FROM run_continuations") == revision &&
            optionalRunRequestSnapshotFromDurableContinuation(f.continuation()).isNone(),
            "an audit failure rolls back the entire Accepted projection, revision and witness")
        f.database.execute("DROP TRIGGER reject_initial_context_audit")
        expect(initialStoreBind(f, request, epoch: f.runtime.activeRun().getOrThrow().epoch), "a rolled-back seed may be retried without hidden work")
    } finally { f.close() }
}

func initialContextStoreFence(scenario: String): Unit {
    let f = ModelLaneCutFixture()
    try {
        let original = initialStoreRequest(f)
        let epoch = f.runtime.activeRun().getOrThrow().epoch
        var request = original
        match (scenario) {
            case "schema" => request = initialStoreField(original, "schema", textValue("axyndra.accepted-context-request/v999"))
            case "unknown-field" => let fields = ArrayList<ValueField>(); for (field in original.fields) { fields.add(field) }
                fields.add(ValueField("approved", boolValue(true))); request = objectValue(fields.toArray())
            case "system-type" => request = initialStoreField(original, "system", objectValue([]))
            case "capability-shape" => request = initialStoreField(original, "capabilities", listValue([textValue("workspace.read")]))
            case "run" => request = initialStoreField(original, "run_id", textValue("other-run"))
            case "thread" => request = initialStoreField(original, "session_id", textValue("other-thread"))
            case "epoch" => request = initialStoreField(original, "epoch", integerValue(epoch + 1))
            case "model" => request = initialStoreField(original, "model", textValue("different-model"))
            case "prompt" => request = initialStoreField(original, "prompt", textValue("different user prompt"))
            case "budget" => request = initialStoreField(original, "budget", objectValue([ValueField("unlimited", boolValue(true))]))
            case "projection" => request = initialStoreField(original, "skill_stack", contextSnapshotValue(persistedContextFixture()))
            case "lane" => request = initialStoreField(original, "lane_id", textValue("other-lane"))
            case "cancelled" => let _ = f.runtime.cancel(0).value().getOrThrow()
            case "pending-call" => expect(isStoreCommitted(f.runtime.commitResult(ResultEnvelope(f.thread, f.turn, f.run, epoch, 1,
                ThreadItemDraft(ItemId("initial-pending"), ThreadItemContent.ToolCall(CanonicalToolCallId("initial-call"), "read", objectValue([])),
                    ItemProvenance("direct_tool", runId: Some(f.run), operationId: Some(OperationId("initial-operation"))))))),
                "fixture commits a real pending Direct call before attempting the initial seed")
            case "work-debt" => f.setDebt(WorkDebtSnapshot(ownedTasks: [OwnedTaskId("still-owned")]))
            case "phase" => let _ = f.cut().value().getOrThrow()
            case _ => ()
        }
        let before = f.continuation().digest
        let revision = f.database.scalarInt("SELECT revision FROM run_continuations")
        let accepted = initialStoreBind(f, request, epoch: epoch,
            input: if (scenario == "user-item") { ThreadItemContent.UserMessage(textMessageParts("forged canonical input")) }
                else { ThreadItemContent.UserMessage(textMessageParts("refresh catalog")) },
            observedAt: if (scenario == "before-start") { 0 } else { 30 })
        expect(!accepted && f.continuation().digest == before &&
            f.database.scalarInt("SELECT revision FROM run_continuations") == revision &&
            f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='initial_context_request_bound'") == 0,
            "initial context rejects " + scenario + " without overwriting its existing durable witness")
    } finally { f.close() }
}
