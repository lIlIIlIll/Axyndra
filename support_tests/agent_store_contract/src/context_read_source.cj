package agent_store_contract

import std.fs.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

class ContextReadStoreFixture {
    let root: String
    let database: SqliteDatabase
    let store: DurableOperationStore
    let runtime: AgentThreadRuntime
    let coordinator: ThreadCoordinator
    let active: ActiveRunSnapshot
    let admission: ContextReadAdmission
    let parentSource: ?OperationRootSource
    let thread = ThreadId("context-read-thread")
    let turn = SemanticTurnId("context-read-turn")
    let run = RunId("context-read-run")
    let operation = OperationId("context-read-operation")
    let item = ItemId("context-read-item")
    let call = ToolCall("context-read-call", HOST_CONTEXT_READ_TOOL,
        objectValue([ValueField("path", textValue("document.cj"))]))
    let plan: NormalizedOperationPlan
    init(mode!: String = "") {
        root = Directory.createTemp("/tmp").toString(); database = SqliteDatabase(root + "/context-read.db")
        let sink = SqliteThreadCommitSink(database)
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("context-read", StoreEstimator()), { => 10 })
        active = runtime.startTurn(turn, run, ItemId("context-read-user"),
            ThreadItemContent.UserMessage(textMessageParts("read preparation")), recoveryLane(), InvocationContextProjection())
            .value().getOrThrow()
        plan = NormalizedOperationPlan(call.name, call.arguments, [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "read-plan-binding",
            toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
        store = DurableOperationStore(database)
        var parent: ?OperationRootSource = None
        if (mode == "committed" || mode == "forged-decision" || mode == "prepared-parent") {
            let actual = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
                ItemId("pending-parent"), "pending-parent-call", "plugin.context.pending", objectValue([]), 10)
            parent = Some(OperationRootSource.Committed(actual))
            if (mode == "forged-decision") {
                parent = Some(OperationRootSource.Committed(runtime.attestCommittedToolCalls([CommittedToolCallSource(ModelDecisionId("wrong-decision"),
                    actual.scopedToolCallId, actual.canonicalItemId, actual.block)]).value().getOrThrow()[0]))
            }
            if (mode == "prepared-parent") {
                let original = NormalizedOperationPlan(actual.block.name, actual.block.arguments,
                    [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "pending-plan")
                store.prepare(OperationId("operation-" + actual.decisionId.value + "-" + actual.scopedToolCallId.value),
                    run, actual, original).value().getOrThrow()
            }
        }
        if (mode == "direct-parent") {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
                ThreadItemDraft(ItemId("pending-direct"), ThreadItemContent.ToolCall(CanonicalToolCallId("pending-direct-call"),
                    "plugin.context.pending", objectValue([])), ItemProvenance("direct_tool", runId: Some(run),
                        operationId: Some(OperationId("pending-direct-operation"))))))), "Direct preflight owns its raw canonical call before a future plan")
            parent = Some(OperationRootSource.Direct(runtime.attestDirectToolCall(ItemId("pending-direct"),
                OperationId("pending-direct-operation"), run, active.epoch).value().getOrThrow()))
        }
        parentSource = parent
        admission = runtime.beginContextRead(call, "axyndra:context-test",
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "read-request", run, active.epoch,
            contextReadProjectionDigest(active.contextSnapshot), parent: parent).value().getOrThrow()
    }
    func commit(): DirectToolCallRef {
        runtime.commitContextReadToolCall(admission, item, operation, call, plan).value().getOrThrow()
    }
    func completeRead(): ContextReadFact {
        let source = commit()
        store.prepareDirectOperation(source, plan).value().getOrThrow()
        store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), operation, run, plan, 11, false).value().getOrThrow()
        store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), operation, run, thread, 12).value().getOrThrow()
        let output = objectValue([ValueField("path", textValue("document.cj")), ValueField("content", textValue("observed data"))])
        let resolution = runtime.resolveOperation(ItemId("result-" + operation.value), operation, CanonicalToolCallId(call.callId), plan,
            OperationAttemptStage.Executing, Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, output))),
            "receipt-" + operation.value, 13, expectedRunId: Some(run), expectedEpoch: Some(active.epoch)).value().getOrThrow()
        expect(resolution.semanticCommit.isSome() && isStoreCommitted(resolution.semanticCommit.getOrThrow()),
            "real context read commits its single Completed result before parent preparation")
        store.loadContextReadFact(operation, run).value().getOrThrow()
    }
    func parentOperation(): OperationId {
        match (parentSource.getOrThrow()) {
            case OperationRootSource.Direct(value) => value.operationId
            case OperationRootSource.Committed(value) => OperationId("operation-" + value.decisionId.value + "-" + value.scopedToolCallId.value)
        }
    }
    func prepareParent(plan: NormalizedOperationPlan): Result<Unit> {
        match (parentSource.getOrThrow()) {
            case OperationRootSource.Direct(value) => store.prepareDirectOperation(value, plan)
            case OperationRootSource.Committed(value) => store.prepare(parentOperation(), run, value, plan)
        }
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func contextReadSourceStoreContract(): Unit {
    for (scenario in ["completed", "primitive", "wrong-run", "wrong-epoch", "changed-plan", "changed-proof", "changed-context", "raw-worker", "cancel", "recovery", "committed", "forged-decision", "prepared-parent", "direct-parent"]) {
        let fixture = ContextReadStoreFixture(mode: scenario)
        try {
            if (scenario == "raw-worker") {
                let origin = ContextReadOrigin("axyndra:context-test",
                    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    contextReadProjectionDigest(fixture.active.contextSnapshot), contextReadPlanDigest(fixture.plan), "forged", "")
                let outcome = fixture.runtime.commitResult(ResultEnvelope(fixture.thread, fixture.turn, fixture.run, fixture.active.epoch, 1,
                    ThreadItemDraft(fixture.item, ThreadItemContent.ToolCall(CanonicalToolCallId(fixture.call.callId), fixture.call.name, fixture.call.arguments),
                        ItemProvenance("direct_tool", runId: Some(fixture.run), operationId: Some(fixture.operation),
                            directOrigin: Some(DirectCallOrigin.ContextRead(origin))))))
                expect(match (outcome) { case SemanticCommitDecision.Rejected(_) => true; case _ => false },
                    "deserialized ContextRead origin cannot mint an internal canonical call")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == 0,
                    "forged source has no durable Item or Operation")
                continue
            }
            if (scenario == "forged-decision" || scenario == "prepared-parent") {
                expect(fixture.runtime.commitContextReadToolCall(fixture.admission, fixture.item, fixture.operation, fixture.call, fixture.plan).isError() &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'") == 0 &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE id='context-read-item'") == 0,
                    scenario + " cannot borrow a false parent decision or mutate an already prepared parent")
                continue
            }
            let source = fixture.commit()
            expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'") == 1 &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == (if (scenario == "committed") { 1 } else { 0 }) &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM runs") == 1,
                "read has one same-Run canonical source with no fabricated model or maintenance Run")
            expect(fixture.runtime.attestDirectToolCall(fixture.item, fixture.operation, fixture.run, fixture.active.epoch).isError(),
                "ordinary Direct attestation cannot remint the context read")
            if (scenario == "primitive") {
                expect(fixture.store.prepareTrustedControlOperation(fixture.operation, fixture.run, fixture.item, fixture.plan).isError(),
                    "primitive IDs cannot prepare a read source")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0, "primitive refusal has no Operation")
                continue
            }
            if (scenario == "wrong-run") {
                expect(fixture.runtime.beginContextRead(fixture.call, "axyndra:test",
                    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "other", RunId("wrong"), fixture.active.epoch,
                    contextReadProjectionDigest(fixture.active.contextSnapshot)).isError(), "read cannot create or switch Run ownership")
                continue
            }
            if (scenario == "wrong-epoch") { fixture.database.execute("UPDATE runs SET epoch=epoch+1") }
            if (scenario == "changed-proof") { fixture.database.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'") }
            if (scenario == "changed-context") { fixture.database.execute("UPDATE runs SET skill_snapshot='invalid'") }
            let plan = if (scenario == "changed-plan") {
                NormalizedOperationPlan(fixture.plan.toolName, objectValue([ValueField("path", textValue("other.cj"))]),
                    fixture.plan.requiredCapabilities, OperationEffectClass.ReadOnly, OperationRetryDisposition.Never,
                    fixture.plan.bindingDigest, toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
                    implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
            } else { fixture.plan }
            let prepared = fixture.store.prepareDirectOperation(source, plan)
            if (["wrong-epoch", "changed-proof", "changed-context", "changed-plan"].contains(scenario)) {
                expect(prepared.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0,
                    scenario + " exact source validation fails before Operation creation")
                continue
            }
            prepared.value().getOrThrow()
            expect(fixture.store.loadContextReadFact(fixture.operation, fixture.run).isError(),
                "Prepared read is not available context data")
            expect(fixture.store.markExecuting(fixture.operation, fixture.run, plan, 11, false).isError(),
                "primitive execution cannot revive a sealed read")
            fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), fixture.operation, fixture.run, plan, 11, false)
                .value().getOrThrow()
            fixture.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), fixture.operation, fixture.run, fixture.thread, 12)
                .value().getOrThrow()
            if (scenario == "cancel") {
                let _ = fixture.runtime.cancel(1000)
                expect(source.validateLiveSource().isError() && fixture.store.loadContextReadFact(fixture.operation, fixture.run).isError(),
                    "cancellation closes read admission without projecting an incomplete read")
                continue
            }
            let output = objectValue([ValueField("path", textValue("document.cj")), ValueField("content", textValue("observed data"))])
            let resolution = fixture.runtime.resolveOperation(ItemId("result-" + fixture.operation.value), fixture.operation,
                CanonicalToolCallId(fixture.call.callId), plan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(fixture.call.callId, output))),
                "receipt-" + fixture.operation.value, 13, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.active.epoch))
                .value().getOrThrow()
            expect(resolution.semanticCommit.isSome() && isStoreCommitted(resolution.semanticCommit.getOrThrow()),
                "read result and one Receipt commit atomically on the existing Run")
            let fact = fixture.store.loadContextReadFact(fixture.operation, fixture.run).value().getOrThrow()
            expect(fact.output().field("content").getOrThrow().text == "observed data" &&
                fact.reference().field("authorizes_effects").getOrThrow().asBool() == false &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
                "only Completed canonical read is returned as immutable untrusted data")
            let changed = fact.output(); changed.put("content", textValue("mutated"))
            expect(fact.output().field("content").getOrThrow().text == "observed data", "read fact output never aliases caller JSON")
            if (scenario == "recovery") {
                fixture.runtime.finish(RunState.Completed, 1000).value().getOrThrow()
                let reopened = SqliteDatabase(fixture.root + "/context-read.db")
                try {
                    let readAgain = DurableOperationStore(reopened).loadContextReadFact(fixture.operation, fixture.run).value().getOrThrow()
                    expect(readAgain.outputDigest == fact.outputDigest && reopened.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1 &&
                        source.validateLiveSource().isError(), "restart reads retained history without minting a grant or replaying I/O")
                } finally { reopened.close() }
            }
        } finally { fixture.close() }
    }
    contextReadFactConsumptionStoreContract()
    println("Context read canonical source contract passed: 14 scenarios")
}
