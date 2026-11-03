package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import agent_testkit.*
import tool_runtime.*

// Real catalog/pipeline admission and read-only token facts. MemoryOperations
// tests classification only; original Product case58 remains the actual Host/
// OS worker/SQL Run cancellation positive and is unchanged by this contract.
class EvidenceCatalogExecutor <: ToolExecutor {
    let catalog: ToolCatalog
    let owner: ToolCatalogOwner
    let source: CancellationSource
    private var wrongPrepared: ?PreparedToolInvocation = None
    let mode: String
    var calls: Int64 = 0
    var cancellations: Int64 = 0
    init(catalog: ToolCatalog, owner: ToolCatalogOwner, source: CancellationSource,
        mode: String) {
        this.catalog = catalog; this.owner = owner; this.source = source
        this.mode = mode
    }
    func bindWrongPrepared(prepared: PreparedToolInvocation): Unit {
        expect(wrongPrepared.isNone() && prepared.source.operationRoot.isSome(),
            "bind the negative fixture once to a real canonical Direct Root")
        wrongPrepared = Some(prepared)
    }
    public func execute(_context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls += 1
        expect(catalog.revokeOwned(owner).isOk(), "revoke the actual active contribution owner")
        if (mode != "live_token") {
            let _ = source.cancel(reason: Some(CancellationReason(CancellationReasonKind.Shutdown,
                "fixture.transport_cancelled", "actual transport stopped", cancelledAtMillis: 123)))
        }
        Result.Err(AgentError(AgentErrorKind.Cancelled, "fixture.transport_cancelled", "actual transport stopped",
            retryable: false, fallbackAllowed: false, fields: [ErrorField("operation", prepared.operationId.value)]))
    }
    public func executeObserved(context: ToolInvocationContext, prepared: PreparedToolInvocation): ToolExecutionOutcome {
        let result = execute(context, prepared)
        let actualError = result.error().getOrThrow()
        let suppliedError = if (mode == "wrong_error") {
            AgentError(AgentErrorKind.Cancelled, actualError.code, actualError.message)
        } else { actualError }
        let suppliedPrepared = if (mode == "wrong_prepared") { wrongPrepared.getOrThrow() } else { prepared }
        let evidence = observeToolExecutionCancellation(context, suppliedPrepared, suppliedError, source.token)
        expect(if (mode == "live_token") { evidence.isNone() } else { evidence.isSome() },
            "all identity counterexamples reach evidence matching with real canonical Root and token facts")
        ToolExecutionOutcome(result, cancellationEvidence: evidence)
    }
    public func cancel(_run: RunId): Result<Unit> { cancellations += 1; Result.Ok(()) }
}

// The SDK-only ownedCatalogPrepare helper has no Runtime Root. This fixture
// uses the existing public canonical commit/attestation/binding path instead.
func evidencePrepareCanonicalDirect(pipeline: ToolPipeline, operations: MemoryOperations,
    runtime: AgentThreadRuntime, coordinator: ThreadCoordinator, context: ToolInvocationContext,
    turn: SemanticTurnId, name: String, suffix: String): PreparedToolInvocation {
    let call = ToolCall("owned-call-" + suffix, name, objectValue([]))
    let raw = sourceReady(pipeline.prepare(context, call))
    expect(raw.source.operationRoot.isNone(), "plain preparation alone does not mint a canonical Root")
    let item = ItemId("evidence-item-" + suffix)
    expect(match (runtime.commitResult(ResultEnvelope(ThreadId(context.sessionId.value), turn, context.runId,
        context.epoch, coordinator.snapshot().nextResultSequence, ThreadItemDraft(item,
            ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
            ItemProvenance("direct_tool", runId: Some(context.runId), operationId: Some(raw.operationId)))))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "commit this exact direct ToolCall and operation in the single actual Runtime")
    let reference = runtime.attestDirectToolCall(item, raw.operationId, context.runId, context.epoch)
        .value().getOrThrow()
    let bound = pipeline.bindDirectRoot(context, raw, reference).value().getOrThrow()
    expect(bound.source.operationRoot.isSome() && bound.source.kind == PreparedInvocationSourceKind.Direct &&
        bound.source.runId.value == context.runId.value && bound.source.epoch == context.epoch &&
        bound.call.callId == call.callId && bound.operationId.value == raw.operationId.value,
        "the original prepared operation borrows its actual canonical Direct Root")
    operations.prepareTrustedControlOperation(bound.operationId, context.runId, item, bound.operationPlan)
        .value().getOrThrow()
    bound
}

func toolExecutionCancellationEvidenceContract(): Unit {
    for (mode in ["valid", "wrong_prepared", "wrong_error", "live_token"]) {
        let catalog = ToolCatalog()
        let owner = ownedCatalogValue(catalog.createContributionOwner("evidence-" + mode, "plugin.evidence."))
        let caller = CancellationSource()
        let transport = CancellationSource()
        try {
            let siblingCounter = ExecutionCounter()
            let sibling = ownedCatalogEntry("evidence_sibling", mode, siblingCounter)
            expect(catalog.register(sibling.descriptor, sibling.executor).isOk(), "register independent same-Run sibling")
            let capabilities = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
            let operations = MemoryOperations()
            let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
            let executor = EvidenceCatalogExecutor(catalog, owner, transport, mode)
            let entry = ownedCatalogEntry("plugin.evidence.echo", mode, ExecutionCounter())
            expect(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
                [ToolCatalogRegistration(entry.descriptor, executor)]).isOk(), "publish observed executor")
            let snapshot = catalog.toolSetSnapshot("evidence-current-" + mode, capabilities)
            let context = ToolInvocationContext(RunId("evidence-run-" + mode), SessionId("evidence-thread"),
                capabilities, epoch: 1, cancellation: caller.token, toolSetSnapshot: Some(snapshot))
            let coordinator = ThreadCoordinator(ThreadId(context.sessionId.value), "/workspace",
                InMemoryThreadCommitSink())
            let runtime = AgentThreadRuntime(coordinator, ContextProjector("evidence-" + mode, SourceEstimator()),
                { => 10 })
            let turn = SemanticTurnId("evidence-turn-" + mode)
            let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses",
                ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", snapshot, "system")
            runtime.startTurn(turn, context.runId, ItemId("evidence-user-" + mode),
                ThreadItemContent.UserMessage(textMessageParts("direct")), lane, InvocationContextProjection())
                .value().getOrThrow()
            let wrongPrepared = evidencePrepareCanonicalDirect(pipeline, operations, runtime, coordinator,
                context, turn, "evidence_sibling", "wrong-" + mode)
            executor.bindWrongPrepared(wrongPrepared)
            let prepared = evidencePrepareCanonicalDirect(pipeline, operations, runtime, coordinator,
                context, turn, "plugin.evidence.echo", "observed-" + mode)
            let result = pipeline.executePrepared(context, prepared)
            expect(result.isError(), "revocation never commits a successful value")
            let error = result.error().getOrThrow()
            if (mode == "valid") {
                expect(error.kind == AgentErrorKind.Cancelled && error.code == "fixture.transport_cancelled" &&
                    error.message == "actual transport stopped" && !error.retryable && !error.fallbackAllowed &&
                    error.field("operation").getOrThrow() == prepared.operationId.value,
                    "exact cancelled execution survives with its actual token and original Err")
            } else {
                expect(error.kind == AgentErrorKind.PermissionDenied && error.code == "tool.revoked_during_execution",
                    "wrong Prepared, cloned Err or live token cannot prove cancellation: " + mode)
            }
            expect(!caller.token.isCancelled() && executor.calls == 1 && executor.cancellations == 1,
                "owned transport cancellation does not cancel the global Run")
            expect(ownedCatalogCode(pipeline.executePrepared(context, prepared), "tool.prepared_registration_missing") &&
                executor.calls == 1, "revocation still prevents another admission")
            ownedCatalogExecute(pipeline, context, ownedCatalogPrepare(pipeline, context,
                "evidence_sibling", "sibling-" + mode), mode)
            expect(siblingCounter.executions == 1 && !caller.token.isCancelled(),
                "same-Run unrelated registration remains executable")
            expect(match (operations.loadCommittedToolResult(prepared.operationId, context.runId)) {
                case Result.Ok(None) => true
                case _ => false
            }, "revoked invocation has no committed successful result")
        } finally { transport.close(); caller.close() }
    }
}
