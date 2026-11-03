package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

class ProductOwnedNestedProbe <: ToolExecutor {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    let done = AtomicBool(false)
    var context: ?ToolInvocationContext = None
    var task: ?Future<Unit> = None
    var nestedError = ""
    public func execute(actual: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        context = Some(actual)
        let allowed = AtomicBool(false); let ready = AtomicBool(false)
        let child = spawn {
            while (!ready.load()) { sleep(Duration.millisecond) }
            if (allowed.load()) {
                let outcome = actual.withNestedToolSlot(prepared.operationId, { =>
                    entered.store(true)
                    let deadline = MonoTime.now() + Duration.second * 10
                    while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
                    Result.Ok(())
                })
                match (outcome) { case Result.Err(error) => nestedError = error.code; case Result.Ok(_) => () }
            }
            done.store(true)
        }
        task = Some(child)
        let owned = actual.ownTask("fixture/nested-" + prepared.operationId.value, child)
        allowed.store(owned.isOk()); ready.store(true)
        match (owned) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let deadline = MonoTime.now() + Duration.second * 5
        while (!entered.load() && !done.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!entered.load()) { release.store(true) }
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.parent_returned_early", "owned child is still active"))
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}

class ProductHeldRootProbe <: ToolExecutor {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}

@Test
class NestedWorkerOwnershipTests {
    @TestCase
    func missingTaskOwnerFailsClosed(): Unit {
        let context = ToolInvocationContext(RunId("not-a-runtime-owner"), SessionId("scope"), CapabilitySet())
        let task = spawn { () }
        try {
            let result = context.ownTask("unowned", task)
            @Expect(result.isError(), true)
            @Expect(result.error().getOrThrow().code, "tool.task_owner_unavailable")
        } finally { task.get() }
    }

    @TestCase
    func directParentReturnRetainsChildSlotAndQuarantinesActualTask(): Unit {
        let files = LifecycleConfigurationFixture()
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
            settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
            approvalMode: ApprovalMode.Yolo, asyncEnabled: false)))
        let database = SqliteDatabase(files.root + "/state/state.db")
        let probe = ProductOwnedNestedProbe()
        let held = ProductHeldRootProbe()
        var later: ?Future<Result<ToolInvocationResult>> = None
        try {
            lifecycleTestRequire(product.registerTool(ToolDescriptor(ModelToolDefinition("plugin.fixture.async",
                "owned asynchronous root fixture", objectValue([])), Capability(CapabilityKind.WorkspaceRead)), probe))
            lifecycleTestRequire(product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.held",
                "next actual Run", objectValue([])), Capability(CapabilityKind.WorkspaceRead)), held))
            let ceiling = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
            let budget = ExecutionBudget(maxConcurrentTools: 1, maxToolCalls: 2)
            let result = product.vnext.executeCanonicalTool(SessionId("direct-owned"), ceiling,
                ToolCall("first", "plugin.fixture.async", objectValue([])), budget: budget)
            @Expect(result.isError(), true)
            @Expect(probe.entered.load() && !probe.done.load(), true)
            @Expect(budget.snapshot().activeTools, 1)
            @Expect(database.query("SELECT state FROM runs")[0].required(0), "recovery_required")
            @Expect(database.query("SELECT outcome FROM operation_receipts")[0].required(0), "unknown")
            probe.release.store(true)
            probe.task.getOrThrow().get()
            @Expect(probe.nestedError, "")
            @Expect(budget.snapshot().activeTools, 0)
            // The same Thread now has a different real Run. The old context's
            // handler must not attach any task to this new owner.
            let next = spawn { product.vnext.executeCanonicalTool(SessionId("direct-owned"), ceiling,
                ToolCall("second", "fixture.held", objectValue([]))) }
            later = Some(next)
            let deadline = MonoTime.now() + Duration.second * 5
            while (!held.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(held.entered.load(), true)
            let finished = spawn { () }
            try {
                let stale = probe.context.getOrThrow().ownTask("late-old-owner", finished)
                @Expect(stale.isError(), true)
                @Expect(stale.error().getOrThrow().code, "runtime.run_stale")
            } finally { finished.get() }
            held.release.store(true)
            @Expect(hostServiceEntrySucceeded(next.get()), true)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally {
            probe.release.store(true); held.release.store(true)
            match (probe.task) { case Some(task) => task.get(); case None => () }
            match (later) { case Some(task) => let _ = task.get(); case None => () }
            let _ = product.close(); database.close(); files.close()
        }
    }
}
