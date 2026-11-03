package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import std.time.*
import tool_runtime.*
import yjson_support.*

func approvalNestedSlotContract(): Unit {
    asynchronousNestedSlotContract()
    for (mode in ["completed", "rejected", "budget", "cancelled", "throwing"]) {
        let runs = MemoryRuns()
        let catalog = ToolCatalog()
        let probe = ApprovalNestedSlotProbe(mode)
        expect(catalog.register(ToolDescriptor(ModelToolDefinition(
            "plugin.contract.approved", "approved nested slot probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true), probe).isOk(),
            "approved nested slot probe registers")
        let model = ApprovalNestedSlotModel()
        let receipts = ApprovalNestedSlotReceiptSink()
        let threads = ApprovalNestedSlotThreads("approval-nested-" + mode, receipts)
        let core = AgentCore(model, runs,
            ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
            threadRuntimes: Some(threads))
        let request = AgentRunRequest(RunId("approval-nested-" + mode), SessionId("approval-nested-" + mode),
            "fixture", "approve one parent and one child",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
            budget: ResourceBudget(maxConcurrentTools: 1,
                maxToolCalls: if (mode == "budget" || mode == "rejected") { 1 } else { 2 }))
        let approval = match (core.start(request).value().getOrThrow()) {
            case AgentRunOutcome.AwaitingApproval(snapshot, value) =>
                expect(snapshot.toolCalls == 1 && probe.executions == 0,
                    "pending approval charged the root exactly once without executing it")
                value
            case _ => throw IllegalStateException("nested slot probe must await User approval")
        }
        if (mode == "rejected") {
            let result = core.decide(request, approval, ApprovalDecision.Reject)
            let completed = completedSnapshotOrThrow(result, "rejected parent continues with no nested work")
            expect(probe.executions == 0 && probe.childExecutions == 0 && completed.toolCalls == 1,
                "reject neither reserves an execution slot nor charges a second root call")
            continue
        }
        let result: Result<AgentRunOutcome>
        if (mode == "cancelled") {
            let pending = spawn { core.decide(request, approval, ApprovalDecision.Approve) }
            let deadline = MonoTime.now() + Duration.second * 3
            while (!probe.childEntered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            let entered = probe.childEntered.load()
            let cancelled = core.cancel(request.runId)
            result = pending.get()
            expect(entered && cancelled.isOk(), "approved child becomes active before cancellation")
            expect(result.isError() && runs.find(request.runId).value().getOrThrow().status == RunState.Cancelled,
                "approved nested cancellation retains the real cancelled Run state")
        } else {
            result = core.decide(request, approval, ApprovalDecision.Approve)
            if (mode == "completed") {
                let _ = completedSnapshotOrThrow(result, "approved parent yields its only slot to its child")
                expect(probe.childExecutions == 1 && probe.reentrantRejected && model.calls == 2,
                    "exactly one child executes and cannot recursively spend the active child slot")
            } else if (mode == "budget") {
                expect(result.isError() && probe.childExecutions == 0,
                    "exhausted child budget rejects before its action starts")
            } else {
                expect(match (result) {
                    case Result.Err(error) => error.code == "tool.executor_panicked" &&
                        !error.message.contains("private exception text")
                    case _ => false
                }, "executor panic becomes a bounded typed failure")
                expect(receipts.values.size == 1 && receipts.values[0].outcome == OperationOutcome.Unknown,
                    "post-handoff executor panic retains an Unknown receipt instead of a prepared failure")
            }
        }
        let usage = probe.ledger.getOrThrow().snapshot()
        expect(probe.executions == 1 && probe.parentBefore == 1 && probe.parentAfter == 1 && usage.activeTools == 0,
            "approval resumes with one parent slot and releases it after success, failure or cancellation")
        expect(usage.toolCalls == (if (mode == "budget") { 1 } else { 2 }),
            "approval continuation never charges the prepared root ToolCall again")
        if (mode != "budget") {
            expect(probe.childActive == 1, "child uses the yielded slot under maxConcurrentTools one")
        }
        if (mode == "budget") {
            expect(probe.nestedError == "budget.tool_calls_exceeded",
                "child budget failure remains a budget error rather than missing parent ownership")
        }
    }
    println("Core approval nested slot contract passed")
}

class ApprovalNestedSlotProbe <: ToolExecutor {
    let mode: String
    let childEntered = AtomicBool(false)
    var ledger: ?ExecutionBudget = None
    var executions: Int64 = 0
    var childExecutions: Int64 = 0
    var parentBefore: Int64 = -1
    var parentAfter: Int64 = -1
    var childActive: Int64 = -1
    var reentrantRejected = false
    var nestedError = ""

    init(mode: String) { this.mode = mode }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        ledger = Some(context.budget)
        executions += 1
        parentBefore = context.budget.snapshot().activeTools
        let nested = context.withNestedToolSlot(prepared.operationId, { =>
            childExecutions += 1
            childActive = context.budget.snapshot().activeTools
            reentrantRejected = match (context.withNestedToolSlot(prepared.operationId, { => Result.Ok(()) })) {
                case Result.Err(error) => error.code == "run.tool_slot_transition_invalid"
                case _ => false
            }
            childEntered.store(true)
            if (mode == "cancelled") {
                let deadline = MonoTime.now() + Duration.second * 5
                while (!context.cancellation.isCancelled() && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 5)
                }
                context.cancellation.check()
            } else { Result.Ok(()) }
        })
        parentAfter = context.budget.snapshot().activeTools
        if (mode == "throwing") { throw IllegalStateException("private exception text") }
        match (nested) {
            case Result.Err(error) => nestedError = error.code; Result.Err(error)
            case Result.Ok(_) => Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
        }
    }
}

class ApprovalNestedSlotReceiptSink <: ThreadCommitSink {
    let recorded = AtomicBool(false)
    let values = ArrayList<VNextOperationReceipt>()
    public func commit(transition: ThreadTransition): Result<Unit> {
        match (transition.operationReceipt) {
            case Some(value) => values.add(value); recorded.store(true)
            case None => ()
        }
        Result.Ok(())
    }
    public func recordOperationReceipt(_runId: RunId, receipt: VNextOperationReceipt): Result<Unit> {
        values.add(receipt); recorded.store(true)
        Result.Ok(())
    }
    public func recordRunTransition(_threadId: ThreadId, _turnId: SemanticTurnId, _runId: RunId,
        _epoch: Int64, _transition: RunTransition, _observedAtMillis: Int64): Result<Unit> { Result.Ok(()) }
    public func recordModelUsage(_sample: RunModelUsageSample): Result<Unit> { Result.Ok(()) }
}

class ApprovalNestedSlotThreads <: ThreadRuntimeRegistry {
    let runtime: AgentThreadRuntime
    init(id: String, sink: ThreadCommitSink) {
        runtime = AgentThreadRuntime(ThreadCoordinator(ThreadId(id), "agent-core", sink),
            ContextProjector("approval-nested", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
    }
    public func acquire(_threadId: ThreadId, _workspaceId: String): Result<AgentThreadRuntime> { Result.Ok(runtime) }
    public func recover(threadId: ThreadId, workspaceId: String): Result<AgentThreadRuntime> {
        acquire(threadId, workspaceId)
    }
    public func releaseInactive(_threadId: ThreadId): Result<Bool> { Result.Ok(false) }
    public func discardInactive(_threadId: ThreadId): Result<Bool> { Result.Ok(false) }
}

class ApprovalNestedSlotModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(_request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "approved-parent-call", name: "plugin.contract.approved", arguments: objectValue([]))]))
        } else {
            Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "approved parent settled")],
                stopReason: "end_turn"))
        }
    }
}

// A real approved Core parent returns while an owned nested action remains
// active. This exercises the actual scheduler; no fabricated slot DTO is used.
func asynchronousNestedSlotContract(): Unit {
    for (quarantine in [false, true]) {
        let runs = MemoryRuns(); let catalog = ToolCatalog()
        let probe = AsyncNestedSlotProbe()
        catalog.register(ToolDescriptor(ModelToolDefinition("plugin.contract.approved", "owned asynchronous probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true), probe).value().getOrThrow()
        let receipts = ApprovalNestedSlotReceiptSink()
        let id = "owned-async-" + quarantine.toString()
        let threads = ApprovalNestedSlotThreads(id, receipts)
        let core = AgentCore(ApprovalNestedSlotModel(), runs,
            ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog, threadRuntimes: Some(threads))
        let request = AgentRunRequest(RunId(id), SessionId(id), "fixture", "retain an asynchronous child",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
            budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2))
        let approval = match (core.start(request).value().getOrThrow()) {
            case AgentRunOutcome.AwaitingApproval(_, value) => value
            case _ => throw IllegalStateException("owned asynchronous parent requires approval")
        }
        let completed = AtomicBool(false)
        let run = spawn {
            try { core.decide(request, approval, ApprovalDecision.Approve) }
            finally { completed.store(true) }
        }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!receipts.recorded.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            expect(receipts.recorded.load() && probe.entered.load(), "actual root Receipt commits before its owned child returns")
            expect(probe.ledger.getOrThrow().snapshot().activeTools == 1,
                "returning parent must not release a slot which still belongs to its active child")
            if (quarantine) {
                let result = run.get()
                expect(result.isError() && completed.load() && !probe.done.load() &&
                    runs.find(request.runId).value().getOrThrow().status == RunState.RecoveryRequired,
                    "finite Run join quarantines the still-owned child instead of claiming successful completion")
                expect(probe.ledger.getOrThrow().snapshot().activeTools == 1, "quarantine retains the real pending slot debt")
            }
            probe.release.store(true)
            let _ = run.get()
            probe.task.getOrThrow().get()
            expect(probe.done.load() && probe.error == "" && probe.ledger.getOrThrow().snapshot().activeTools == 0,
                "actual late child return releases exactly once without run.tool_slot_missing")
        } finally {
            probe.release.store(true)
            let _ = run.get()
            match (probe.task) { case Some(task) => task.get(); case None => () }
        }
    }
    println("Core asynchronous nested ownership contract passed: held slot, joined and quarantined returns")
}

class AsyncNestedSlotProbe <: ToolExecutor {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    let done = AtomicBool(false)
    var ledger: ?ExecutionBudget = None
    var task: ?Future<Unit> = None
    var error = ""
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        ledger = Some(context.budget)
        let admitted = AtomicBool(false); let ready = AtomicBool(false)
        let child = spawn {
            while (!ready.load()) { sleep(Duration.millisecond) }
            if (admitted.load()) {
                let outcome = context.withNestedToolSlot(prepared.operationId, { =>
                    entered.store(true)
                    let deadline = MonoTime.now() + Duration.second * 10
                    while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
                    Result.Ok(())
                })
                match (outcome) { case Result.Err(value) => error = value.code; case Result.Ok(_) => () }
            }
            done.store(true)
        }
        task = Some(child)
        let owned = context.ownTask("test/nested-" + prepared.operationId.value, child)
        admitted.store(owned.isOk()); ready.store(true)
        match (owned) { case Result.Err(value) => return Result.Err(value); case Result.Ok(_) => () }
        let deadline = MonoTime.now() + Duration.second * 5
        while (!entered.load() && !done.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!entered.load()) { release.store(true); return Result.Err(AgentError(AgentErrorKind.Internal, "fixture.child_not_entered", error)) }
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.parent_returned_early", "owned child is deliberately still active"))
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}
