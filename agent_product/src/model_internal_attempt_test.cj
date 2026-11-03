package agent_product

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class InternalClaimMutationState {
    var auditId = ""
    var auditPayload = ""
    var attemptId = ""
    var transcript = ""
}
class InternalModelFixtureIds <: IdGenerator {
    var next: Int64 = 0
    public func nextRunId(): RunId { RunId("unused-internal-run") }
    public func nextSessionId(): SessionId { SessionId("unused-internal-session") }
    public func nextOperationId(): OperationId { next += 1; OperationId("internal-approval-op-" + next.toString()) }
}
class InternalApprovalTool <: ToolExecutor {
    var calls: Int64 = 0
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls += 1; Result.Ok(ToolResult(prepared.call.callId, textValue("executed")))
    }
}
class InternalApprovalModel <: ModelPort {
    let provider: ModelPort
    init(provider: ModelPort) { this.provider = provider }
    public func transcriptSnapshot(request: ModelRequest): ?String { provider.transcriptSnapshot(request) }
    public func validateTranscriptSnapshot(value: String): Bool { provider.validateTranscriptSnapshot(value) }
    public func cancel(id: String): Result<Unit> { provider.cancel(id) }
    public func execute(request: ModelRequest, sink: ModelEventSink): Result<ModelReply> {
        if (request.tools.isEmpty()) { return provider.execute(request, sink) }
        let evidence = TerminalEvidence("fixture", "message_stop", rawStopReason: "tool_use",
            messageTerminalObserved: true, streamEofObserved: true, adapterVersion: "fixture-v1")
        sink(ModelEvent.ProviderProgress(ProviderStreamEvent.MessageTerminalObserved(evidence)))
        Result.Ok(ModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "review-write",
            name: "fixture_review_write", arguments: objectValue([]))], stopReason: "tool_use",
            terminalEvidence: Some(evidence), completionDisposition: CompletionDisposition.ToolUse,
            decisionOutcome: DecisionOutcome.ToolCalls, validationVersion: 1))
    }
}
class InternalModelFixture {
    let provider: ModelProviderProductFixture
    let control: ControlledModelPort
    let core: AgentCore
    let runs: SqliteRunRepository
    let tool: InternalApprovalTool
    let parent: AgentRunRequest
    init(approval!: Bool = false, mode!: String = "success", thinkingCapabilities!: ?ThinkingCapabilities = None) {
        let actual = ModelProviderProductFixture(mode: mode, thinkingCapabilities: thinkingCapabilities)
        let repository = SqliteRunRepository(actual.database)
        let model = ControlledModelPort(InternalApprovalModel(actual.port), runs: Some(repository))
        let catalog = ToolCatalog(); let executor = InternalApprovalTool(); let operations = DurableOperationStore(actual.database)
        if (approval) { catalog.register(ToolDescriptor(ModelToolDefinition("fixture_review_write", "Approval fixture",
            objectValue([ValueField("type", textValue("object"))])), Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true, neverReplay: true), executor).value().getOrThrow() }
        let engine = AgentCore(model, repository,
            ToolPipeline(catalog, operations, SqliteAuditRepository(actual.database), InternalModelFixtureIds()), catalog,
            threadRuntimes: Some(actual.runtimes), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(actual.database)),
            contextManifestRuntime: Some(ProductContextManifestRuntime(actual.database)))
        let request = AgentRunRequest(RunId("internal-owned-run"), SessionId("provider-thread"), "fixture-model", "review",
            thinking: ThinkingLevel.Off, modelCapabilitiesSnapshot: Some(actual.capabilities), autoRetry: false,
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
            approvalModeOverride: Some(ApprovalMode.AlwaysAsk),
            budget: ResourceBudget(maxModelRequests: 4, maxWallMillis: 20000, maxIdleMillis: 10000))
        this.provider = actual; this.control = model; this.core = engine; this.runs = repository
        this.tool = executor; this.parent = request
        if (approval) {
            let result = engine.start(request)
            if (result.isError() || actual.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='waiting_approval'") != 1) {
                throw IllegalStateException("fixture failed to create the actual pending canonical Tool approval")
            }
        }
    }
    func request(): ModelRequest { ModelRequest("fixture-model", [ModelMessage(ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "bounded internal review")])], requestId: "review-input",
        thinking: ThinkingLevel.Off, tools: [], parallelToolCalls: false, toolChoice: ModelToolChoice.NoTools, streaming: false) }
    func call(purpose: InternalModelPurpose): Result<ModelReply> {
        control.executeInternal(request(), InternalModelCallOptions(parent: Some(parent), purpose: Some(purpose),
            timeoutMillis: 10000, maxAttempts: 1, standaloneAccounting: purpose == InternalModelPurpose.ContextCompaction))
    }
    func continuation(): String { provider.database.query("SELECT payload FROM run_continuations WHERE run_id='internal-owned-run'")[0].required(0) }
    func close(): Unit { let _ = core.cancel(parent.runId); provider.close() }
}

@Test
class InternalModelAttemptTests {
    @TestCase
    func maintenanceCreatesActualAttemptWithoutToolOrConversationDecision(): Unit {
        let fixture = InternalModelFixture()
        try {
            let result = fixture.call(InternalModelPurpose.ContextCompaction)
            @Expect(result.isOk())
            @Expect(fixture.provider.factory.count() == 1 && fixture.provider.factory.allClosed())
            let db = fixture.provider.database
            @Expect(db.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'") == 1)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='completed' AND dispatch_state='dispatch_claimed'") == 1)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 && db.scalarInt("SELECT COUNT(*) FROM operations") == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='internal_model_prepared'") == 1 &&
                db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='internal_model_settled'") == 1)
            @Expect(db.scalarInt("SELECT SUM(actual_input_tokens) FROM run_model_usage") == 11)
            let recorded = fixture.runs.find(fixture.parent.runId).value().getOrThrow()
            @Expect(recorded.kind == RunKind.Compaction && recorded.modelRequests == 1 && recorded.inputTokens == 11)
            let totals = fixture.runs.stats(fixture.parent.sessionId).value().getOrThrow()
            @Expect(totals.modelRequests == 1 && totals.inputTokens == 11 && totals.lastInputTokens == 0)
        } finally { fixture.close() }
    }
    @TestCase
    func reviewerPreservesOriginalApprovalAndBudgetWhileUsingActualProvider(): Unit {
        let fixture = InternalModelFixture(approval: true)
        try {
            let before = fixture.continuation(); let db = fixture.provider.database
            let originalDecisions = db.scalarInt("SELECT COUNT(*) FROM model_decisions")
            let result = fixture.call(InternalModelPurpose.ApprovalReview)
            @Expect(result.isOk() && fixture.provider.factory.count() == 1)
            @Expect(fixture.continuation() == before && fixture.tool.calls == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM runs WHERE state='waiting_approval'") == 1)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions") == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_decisions") == originalDecisions)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review' AND lifecycle='completed'") == 1)
            @Expect(fixture.runs.find(fixture.parent.runId).value().getOrThrow().modelRequests == 2)
        } finally { fixture.close() }
    }
    @TestCase
    func compactionCannotBypassTheExistingActiveThread(): Unit {
        let fixture = InternalModelFixture(approval: true)
        try {
            let before = fixture.continuation(); let count = fixture.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            @Expect(fixture.call(InternalModelPurpose.ContextCompaction).isError())
            @Expect(fixture.continuation() == before && fixture.provider.factory.count() == 0)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == count)
        } finally { fixture.close() }
    }
    @TestCase
    func changedParentAfterClaimCannotOpenProviderResources(): Unit {
        let fixture = InternalModelFixture(approval: true)
        let db = fixture.provider.database
        let prior = db.query("SELECT digest FROM run_continuations WHERE run_id='internal-owned-run'")[0].required(0)
        try {
            fixture.provider.factory.beforeOpen = { _ => db.execute("UPDATE run_continuations SET digest='changed' WHERE run_id='internal-owned-run'") }
            @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isError())
            @Expect(fixture.provider.factory.count() == 0 && fixture.tool.calls == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review' AND lifecycle='completed'") == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions") == 0)
        } finally {
            db.execute("UPDATE run_continuations SET digest=? WHERE run_id='internal-owned-run'", [SqlParameter.Text(prior)])
            fixture.close()
        }
    }
    @TestCase
    func incompleteInternalReplyDoesNotConsumeApprovalOrRetry(): Unit {
        let fixture = InternalModelFixture(approval: true, mode: "partial_eof")
        try {
            let before = fixture.continuation()
            @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isError())
            @Expect(fixture.provider.factory.count() == 1 && fixture.provider.factory.allClosed())
            @Expect(fixture.continuation() == before && fixture.tool.calls == 0)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM approval_decisions") == 0)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review'") == 1)
        } finally { fixture.close() }
    }
    @TestCase
    func actualInternalCancellationRetainsApprovalAndJoinsProvider(): Unit {
        let fixture = InternalModelFixture(approval: true, mode: "hang")
        try {
            let before = fixture.continuation()
            let pending = spawn { fixture.call(InternalModelPurpose.ApprovalReview) }
            let deadline = MonoTime.now() + Duration.second * 10
            while (fixture.provider.factory.count() == 0 && pending.tryGet().isNone() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(fixture.provider.factory.count() == 1)
            @Expect(fixture.control.cancel("review-input").isOk())
            let result = pending.get()
            @Expect(result.isError() && fixture.provider.factory.allClosed())
            @Expect(fixture.continuation() == before && fixture.tool.calls == 0)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review' AND lifecycle='cancelled'") == 1)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM approval_decisions") == 0)
        } finally { fixture.close() }
    }

    @TestCase
    func maintenanceCancellationUsesItsActualRunTerminalAndClosesResources(): Unit {
        let fixture = InternalModelFixture(mode: "hang")
        let pending = spawn { fixture.call(InternalModelPurpose.ContextCompaction) }
        try {
            let deadline = MonoTime.now() + Duration.second * 10
            while (fixture.provider.factory.count() == 0 && pending.tryGet().isNone() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(fixture.provider.factory.count() == 1)
            @Expect(fixture.control.cancel("review-input").isOk())
            @Expect(pending.get().isError() && fixture.provider.factory.allClosed())
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelled'"), 1)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='cancelled'"), 1)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally {
            try { let _ = fixture.control.cancel("review-input"); let _ = pending.get() }
            finally { fixture.close() }
        }
    }

    @TestCase
    func concurrentApprovalAndReopenedRepositoryCannotConsumeLiveReview(): Unit {
        let fixture = InternalModelFixture(approval: true); let db = fixture.provider.database
        let checked = AtomicBool(false)
        try {
            let before = fixture.continuation()
            fixture.provider.factory.beforeOpen = { actual =>
                let reopened = SqliteRunRepository(db)
                let continuation = reopened.continuation(fixture.parent.runId).value().getOrThrow()
                let approval = continuation.approval
                let decision = ApprovalDecisionReceipt(approval.operationId, fixture.parent.runId, fixture.parent.sessionId,
                    approval.callId, approval.argumentHash, ApprovalDecision.Approve)
                @Expect(reopened.recordDecision(decision).isError())
                @Expect(fixture.core.decide(fixture.parent, approval, ApprovalDecision.Approve, { _ => () }).isError())
                @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions"), 0)
                @Expect(fixture.tool.calls == 0 && fixture.continuation() == before)
                let attempt = reopened.modelAttempt(actual.attemptId).value().getOrThrow()
                let sequence = reopened.events(fixture.parent.runId, 0).value().getOrThrow().nextSequence
                let event = AgentEvent(EventMeta(sequence, TraceId("duplicate-review"), fixture.parent.runId,
                    occurredAtMillis: agentUtcMillis(), requestId: Some(RequestId(actual.requestId)),
                    semanticRequestId: Some(attempt.semanticRequestId), attemptId: Some(actual.attemptId)),
                    AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([])))
                let wrongClaim = AgentEvent(EventMeta(sequence, TraceId("wrong-review"), fixture.parent.runId,
                    occurredAtMillis: agentUtcMillis(), requestId: Some(RequestId("forged")),
                    semanticRequestId: Some(attempt.semanticRequestId), attemptId: Some(actual.attemptId)),
                    AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([])))
                @Expect(reopened.claimModelAttemptDispatch(actual.attemptId, wrongClaim).isError())
                let wrongEpoch = InternalModelAttemptInput(InternalModelPurpose.ApprovalReview,
                    actual.threadId, actual.runId, actual.epoch + 1, fixture.provider.gate.request.getOrThrow())
                @Expect(reopened.settleInternalModelAttempt(actual.attemptId, wrongEpoch,
                    Result<ModelReply>.Err(AgentError(AgentErrorKind.Internal, "fixture.failure", "fixture")), agentUtcMillis()).isError())
                @Expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='internal_model_settled'"), 0)
                @Expect(reopened.modelAttempt(actual.attemptId).value().getOrThrow().lifecycle == ModelAttemptLifecycle.Streaming)
                let repeated = reopened.claimModelAttemptDispatch(actual.attemptId, event)
                @Expect(repeated.isOk() && !repeated.value().getOrThrow())
                checked.store(true)
            }
            @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isOk() && checked.load())
            @Expect(fixture.provider.factory.count() == 1 && fixture.continuation() == before)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func exactClaimedInputCannotBeReusedAndNextReviewConsumesSameRunBudget(): Unit {
        let fixture = InternalModelFixture(approval: true)
        try {
            let before = fixture.continuation()
            @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isOk())
            let exact = fixture.provider.gate.request.getOrThrow()
            @Expect(fixture.provider.port.execute(exact, { _ => () }).isError())
            @Expect(fixture.provider.factory.count() == 1)
            @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isOk())
            @Expect(fixture.provider.factory.count() == 2 && fixture.continuation() == before)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(DISTINCT provider_request_id) FROM model_attempts WHERE policy_reason='internal_approval_review'"), 2)
            @Expect(fixture.runs.find(fixture.parent.runId).value().getOrThrow().modelRequests, 3)
            @Expect(fixture.provider.database.scalarInt("SELECT COUNT(*) FROM run_model_usage WHERE role='reviewer'"), 2)
            @Expect(fixture.provider.database.scalarInt("SELECT SUM(actual_input_tokens) FROM run_model_usage WHERE role='reviewer'"), 22)
            @Expect(fixture.tool.calls == 0 && fixture.provider.database.scalarInt("SELECT COUNT(*) FROM approval_decisions") == 0)
        } finally { fixture.close() }
    }

    @TestCase
    func actualClaimFencesEpochPhaseNeutralInputAndTranscriptBeforeIo(): Unit {
        for (mutation in ["epoch", "phase", "neutral_input", "transcript"]) {
            let fixture = InternalModelFixture(approval: true); let db = fixture.provider.database
            let epoch = db.query("SELECT epoch FROM runs WHERE id='internal-owned-run'")[0].required(0)
            let mutationState = InternalClaimMutationState()
            try {
                let before = fixture.continuation()
                fixture.provider.factory.beforeOpen = { actual =>
                    mutationState.attemptId = actual.attemptId.value
                    if (mutation == "epoch") {
                        db.execute("UPDATE runs SET epoch=epoch+1 WHERE id='internal-owned-run'")
                    } else if (mutation == "phase") {
                        db.execute("UPDATE runs SET state='running' WHERE id='internal-owned-run'")
                    } else if (mutation == "neutral_input") {
                        let row = db.query("SELECT id,payload FROM audit_events WHERE kind='internal_model_prepared'")[0]
                        mutationState.auditId = row.required(0); mutationState.auditPayload = row.required(1)
                        let witness = decodeStoredValue(mutationState.auditPayload)
                        witness.field("input").getOrThrow().put("request_id", textValue("forged-request"))
                        let changed = encodeStoredValue(witness)
                        @Expect(changed != mutationState.auditPayload)
                        db.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text(changed), SqlParameter.Text(mutationState.auditId)])
                    } else {
                        mutationState.transcript = db.query("SELECT transcript_snapshot FROM model_attempts WHERE id=?", [SqlParameter.Text(mutationState.attemptId)])[0].required(0)
                        db.execute("UPDATE model_attempts SET transcript_snapshot='forged-provider-state' WHERE id=?", [SqlParameter.Text(mutationState.attemptId)])
                    }
                }
                @Expect(fixture.call(InternalModelPurpose.ApprovalReview).isError())
                @Expect(fixture.provider.factory.count() == 0 && fixture.tool.calls == 0)
                @Expect(fixture.continuation() == before)
                @Expect(db.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review' AND lifecycle='completed'"), 0)
                @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions"), 0)
            } finally {
                db.execute("UPDATE runs SET epoch=?,state='waiting_approval' WHERE id='internal-owned-run'", [SqlParameter.Text(epoch)])
                if (mutationState.auditId != "") { db.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text(mutationState.auditPayload), SqlParameter.Text(mutationState.auditId)]) }
                if (mutationState.transcript != "") { db.execute("UPDATE model_attempts SET transcript_snapshot=? WHERE id=?", [SqlParameter.Text(mutationState.transcript), SqlParameter.Text(mutationState.attemptId)]) }
                fixture.close()
            }
        }
    }

    @TestCase
    func parentChangeAfterActualBytesCannotAcceptTheLateReply(): Unit {
        let fixture = InternalModelFixture(approval: true); let db = fixture.provider.database
        let previous = db.query("SELECT digest FROM run_continuations WHERE run_id='internal-owned-run'")[0].required(0)
        let changed = AtomicBool(false)
        try {
            let before = fixture.continuation()
            let result = fixture.control.executeInternal(fixture.request(), InternalModelCallOptions(
                parent: Some(fixture.parent), purpose: Some(InternalModelPurpose.ApprovalReview), maxAttempts: 1), events: { event =>
                match (event) { case ModelEvent.TextDelta(_) => if (!changed.load()) {
                    changed.store(true)
                    db.execute("UPDATE run_continuations SET digest='late-parent-changed' WHERE run_id='internal-owned-run'") }
                    case _ => () }
            })
            @Expect(changed.load() && fixture.provider.factory.count() == 1)
            @Expect(result.isError() && fixture.provider.factory.allClosed())
            @Expect(fixture.continuation() == before && fixture.tool.calls == 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='internal_model_settled'"), 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_approval_review' AND lifecycle='completed'"), 0)
            @Expect(db.scalarInt("SELECT COUNT(*) FROM approval_decisions"), 0)
        } finally {
            db.execute("UPDATE run_continuations SET digest=? WHERE run_id='internal-owned-run'", [SqlParameter.Text(previous)])
            fixture.close()
        }
    }

    @TestCase
    func typedCallWithoutRuntimeOwnerCannotDelegateToBareModelPort(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let bare = ControlledModelPort(fixture.port)
            let result = bare.executeInternal(fixture.directRequest(), InternalModelCallOptions(
                parent: Some(AgentRunRequest(RunId("no-owner"), SessionId("provider-thread"), "fixture-model", "review")),
                purpose: Some(InternalModelPurpose.ApprovalReview)))
            @Expect(result.isError() && result.error().getOrThrow().code == "model.internal_owner_required")
            @Expect(fixture.factory.count() == 0 && fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0)
        } finally { fixture.close() }
    }
}
