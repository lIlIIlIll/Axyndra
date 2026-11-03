package agent_store_contract

import std.fs.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func directDerivedOperationAdmissionContract(): Unit {
    directDerivedOperationAdmissionFor("host.process.readonly")
    directDerivedOperationAdmissionFor("host.file.plan.propose")
    for (scenario in ["budget", "missing-stage", "wrong-stage", "completed", "unknown",
        "handoff", "stale-epoch", "terminal-run", "executing-error"]) {
        preparedFailureCommitContract(scenario)
    }
}

func preparedFailureCommitContract(scenario: String): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/prepared-failure.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("prepared-thread")
        let turn = SemanticTurnId("prepared-turn")
        let run = RunId("prepared-run")
        let operation = OperationId("prepared-operation")
        let callItem = ItemId("prepared-call-item")
        let callId = CanonicalToolCallId("prepared-call")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("prepared", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("prepared-user"),
            ThreadItemContent.UserMessage(textMessageParts("prepared failure")),
            recoveryLane(), InvocationContextProjection()).value().getOrThrow()
        let plan = NormalizedOperationPlan("plugin.prepared.echo", objectValue([]),
            [Capability(CapabilityKind.ExtensionInvoke)], OperationEffectClass.WorkspaceMutation,
            OperationRetryDisposition.Never, "prepared-root-binding")
        expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
            ThreadItemDraft(callItem, ThreadItemContent.ToolCall(callId, plan.toolName, plan.canonicalArguments),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(operation)))))),
            "pre-execution settlement starts from a canonical Direct call")
        let store = DurableOperationStore(database)
        store.prepareTrustedControlOperation(operation, run, callItem, plan).value().getOrThrow()
        if (scenario == "handoff" || scenario == "executing-error") {
            store.markExecuting(operation, run, plan, 11, false).value().getOrThrow()
            store.markExecutionHandoff(operation, run, thread, 12).value().getOrThrow()
            if (scenario == "handoff") {
                // Even a restored/stale prepared state cannot erase durable
                // evidence that this operation reached executor handoff.
                database.execute("UPDATE operations SET state='prepared' WHERE id='prepared-operation'")
            }
        }
        if (scenario == "budget" || scenario == "executing-error") {
            let stage = if (scenario == "budget") {
                OperationAttemptStage.Prepared
            } else { OperationAttemptStage.Executing }
            let budget = ExecutionBudget(maxToolCalls: 1)
            budget.reserve(BudgetCharge(toolCalls: 1)).value().getOrThrow()
            let budgetError = budget.reserve(BudgetCharge(toolCalls: 1)).error().getOrThrow()
            let resolved = runtime.resolveOperation(ItemId("prepared-result"), operation, callId, plan, stage,
                Result<ToolInvocationResult>.Err(budgetError),
                "prepared-receipt", 13, expectedRunId: Some(run), expectedEpoch: Some(active.epoch))
                .value().getOrThrow()
            expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()),
                scenario + " commits a canonical paired ToolResult with its Receipt")
            let rows = database.query("SELECT o.state,r.outcome,r.verification FROM operations o " +
                "JOIN operation_receipts r ON r.operation_id=o.id WHERE o.id='prepared-operation'")
            let expectedOutcome = if (scenario == "budget") { "failed" } else { "unknown" }
            let expectedState = if (scenario == "budget") { "committed" } else { "recovery_required" }
            let expectedStage = if (scenario == "budget") { "prepared" } else { "executing" }
            expect(rows.size == 1 && rows[0].required(0) == expectedState &&
                rows[0].required(1) == expectedOutcome &&
                decodeStoredValue(rows[0].required(2)).field("stage").getOrThrow().text == expectedStage,
                scenario + " retains the correct effect certainty and execution stage")
            let terminal = if (scenario == "budget") { RunState.Failed } else { RunState.RecoveryRequired }
            expect(runtime.finish(terminal, 1000).isOk() && runtime.activeRun().isNone() &&
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 1,
                scenario + " settles its Run without losing or duplicating the canonical ToolResult")
            let expectedHandoffs: Int64 = if (scenario == "budget") { 0 } else { 1 }
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events " +
                "WHERE kind='operation_execution_handoff'") == expectedHandoffs,
                scenario + " preserves the actual executor handoff facts")
        } else {
            if (scenario == "stale-epoch") {
                database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='prepared-run'")
            }
            if (scenario == "terminal-run") {
                database.execute("UPDATE runs SET state='cancelled' WHERE id='prepared-run'")
            }
            let outcome = if (scenario == "completed") { OperationOutcome.Completed }
                else if (scenario == "unknown") { OperationOutcome.Unknown } else { OperationOutcome.Failed }
            let verification = if (scenario == "missing-stage") { objectValue([]) } else {
                objectValue([ValueField("stage", textValue(
                    if (scenario == "wrong-stage") { "executing" } else { "prepared" }))])
            }
            let rejected = coordinator.commitOperationResult(ResultEnvelope(thread, turn, run, active.epoch, 2,
                ThreadItemDraft(ItemId("prepared-result"), ThreadItemContent.ToolResult(callId, operation,
                    "prepared-receipt", objectValue([]), outcome != OperationOutcome.Completed),
                    ItemProvenance("operation", runId: Some(run), operationId: Some(operation)))),
                VNextOperationReceipt("prepared-receipt", operation, outcome, objectValue([]), verification, 13),
                "running")
            expect(match (rejected) {
                case SemanticCommitDecision.Rejected(_) => true
                case _ => false
            }, scenario + " cannot use the pre-execution failure exception")
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 0 &&
                database.query("SELECT state FROM operations WHERE id='prepared-operation'")[0].required(0) == "prepared" &&
                coordinator.snapshot().thread.revision == 2,
                scenario + " rejected settlement rolls back Receipt, Operation and canonical Item together")
        }
        expect(database.query("PRAGMA foreign_key_check").isEmpty(), scenario + " retains durable referential integrity")
    } finally { database.close() }
}

func directDerivedOperationAdmissionFor(serviceName: String): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/direct-derived.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("direct-durable-thread")
        let turn = SemanticTurnId("direct-durable-turn")
        let run = RunId("direct-durable-run")
        let item = ItemId("direct-durable-item")
        let parent = OperationId("direct-durable-parent")
        let call = ToolCall("direct-durable-call", "plugin.direct.echo", objectValue([]))
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("direct", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("direct-durable-user"),
            ThreadItemContent.UserMessage(textMessageParts("direct")), recoveryLane(), InvocationContextProjection())
            .value().getOrThrow()
        expect(match (runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
            ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))) {
            case SemanticCommitDecision.Committed(_, _) => true
            case _ => false
        }, "durable Direct source commits its own canonical Item")
        let source = OperationRootSource.Direct(runtime.attestDirectToolCall(item, parent, run, active.epoch)
            .value().getOrThrow())
        let rootPlan = NormalizedOperationPlan(call.name, call.arguments,
            [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never, "direct-root-binding")
        let childPlan = NormalizedOperationPlan(serviceName, objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Safe, "direct-child-binding")
        let store = DurableOperationStore(database)
        expect(match (store.operationRunId(parent)) {
            case Result.Err(error) => error.kind == AgentErrorKind.InvalidInput && error.code == "operation.not_found"
            case _ => false
        }, "unprepared canonical Item does not invent a persisted Operation owner")
        store.prepareTrustedControlOperation(parent, run, item, rootPlan).value().getOrThrow()
        expect(store.operationRunId(parent).value().getOrThrow().value == run.value,
            "durable owner lookup reads the persisted Direct root Run")
        let prefix = "javascript-service:" + call.callId + ":"
        expect(store.prepareDerivedOperation(OperationId("direct-early"), parent, run,
            source, prefix + "early", childPlan).isError(), "Direct child cannot precede executor handoff")
        store.markExecuting(parent, run, rootPlan, 11, false).value().getOrThrow()
        expect(store.prepareDerivedOperation(OperationId("direct-executing-only"), parent, run,
            source, prefix + "executing", childPlan).isError(), "executing state alone is not a Direct handoff")
        store.markExecutionHandoff(parent, run, thread, 12).value().getOrThrow()
        expect(store.prepareDerivedOperation(OperationId("direct-wrong-parent"), OperationId("another-parent"),
            run, source, prefix + "wrong-parent", childPlan).isError(), "Direct reference pins its own parent Operation")
        database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='direct-durable-run'")
        expect(store.prepareDerivedOperation(OperationId("direct-stale"), parent, run,
            source, prefix + "stale", childPlan).isError(), "durable epoch fence rejects a stale sealed Direct reference")
        database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='direct-durable-run'")
        let writePlan = NormalizedOperationPlan(serviceName, objectValue([]),
            [Capability(CapabilityKind.WorkspaceWrite)], OperationEffectClass.WorkspaceMutation,
            OperationRetryDisposition.Never, "write-binding")
        let capabilityEscalation = NormalizedOperationPlan(serviceName, objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.ProcessSpawn)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "process-cap-binding")
        let networkEscalation = NormalizedOperationPlan(serviceName, objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Safe, "network-binding",
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.HostNetwork)))
        expect(store.prepareDerivedOperation(OperationId("direct-write"), parent, run,
            source, prefix + "write", writePlan).isError() &&
            store.prepareDerivedOperation(OperationId("direct-cap"), parent, run,
                source, prefix + "cap", capabilityEscalation).isError() &&
            store.prepareDerivedOperation(OperationId("direct-network"), parent, run,
                source, prefix + "network", networkEscalation).isError() &&
            store.prepareDerivedOperation(OperationId("direct-unbound-request"), parent, run,
                source, "javascript-service:another-call:read", childPlan).isError(),
            "Direct children cannot expand write, process or network authority or impersonate another call")
        let child = OperationId("direct-admitted-child")
        expect(store.prepareDerivedOperation(child, parent, run, source, prefix + "read", childPlan).isOk(),
            "Direct root admits the same generic read-only port through the canonical operation authority")
        expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM decision_operations") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM operations WHERE tool_call_item_id='direct-durable-item'") == 2,
            "Direct child retains the original Item and introduces no fake model Decision")
        expect(store.prepareDerivedOperation(OperationId("direct-retry"), parent, run,
            source, prefix + "read", childPlan).value().getOrThrow().value == child.value,
            "Direct request replay retains its original admitted Operation identity")
        store.markExecuting(child, run, childPlan, 13, false).value().getOrThrow()
        store.markExecutionHandoff(child, run, thread, 14).value().getOrThrow()
        match (store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-" + child.value, child,
            OperationOutcome.Completed, objectValue([]), objectValue([]), 15))) {
            case Result.Ok(_) => ()
            case Result.Err(error) => throw IllegalStateException(error.describe())
        }
        expect(store.loadDerivedOperationReceipt(child, run).value().getOrThrow().isSome(),
            "Direct derived execution commits a receipt through the existing settlement contract")
        expect(store.operationRunId(child).value().getOrThrow().value == run.value,
            "owner lookup preserves the completed child's canonical Run")
        database.execute("UPDATE runs SET state='cancelled' WHERE id='direct-durable-run'")
        expect(store.prepareDerivedOperation(OperationId("direct-after-cancel"), parent, run,
            source, prefix + "after-cancel", childPlan).isError(), "cancelled Direct run cannot admit another child")
        expect(store.prepareDerivedOperation(OperationId("direct-terminal-replay"), parent, run,
            source, prefix + "read", childPlan).value().getOrThrow().value == child.value,
            "terminal Direct replay may retrieve its receipt without reviving execution authority")
        expect(store.operationRunId(parent).value().getOrThrow().value == run.value,
            "historical ownership remains readable after cancellation without granting fresh admission")
        expect(database.query("PRAGMA foreign_key_check").isEmpty(), "Direct ancestry remains referentially valid")
    } finally { database.close() }
}
