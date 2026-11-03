package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func observedManagedAckJob(runtime: ProductTaskRuntime, thread: SessionId, id: String): ProductAsyncJobSnapshot {
    for (job in runtime.jobsFor(thread) where job.id == id) { return job }
    throw IllegalStateException("actual managed job disappeared from its owner")
}

@Test
class ManagedJobLateCleanupAckTests {
    @TestCase
    func actualCleanupAckClearsExecutingOnceWithoutRefundingUnknown(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true)
        let runtime = ProductTaskRuntime(asyncEnabled: true)
        let port = LocalProcessPort(LocalWorkspace(fixture.files.workspace), sandboxEnabled: true)
        let allowAck = AtomicBool(false)
        let actualAck = AtomicBool(false)
        let thread = SessionId("managed-late-ack")
        var retained: ?ProductPluginLifecycleManager = None
        try {
            // The same real Task owner/API is used; its callback can delay an
            // actual service ACK, but cannot manufacture one or bypass cleanup.
            runtime.attach(fixture.product, ProductTaskPersistence(fixture.database))
            let launcher: ProductManagedJobLauncher = { context, prepared, acknowledged =>
                runtime.startManagedJob(fixture.product.vnext, context, prepared, { =>
                    let ready = acknowledged()
                    if (ready) { actualAck.store(true) }
                    allowAck.load() && ready
                })
            }
            let manager = lifecycleTestRequire(fixture.product.vnext.createPluginLifecycleManager(port,
                managedJobLauncher: Some(launcher)))
            retained = Some(manager)
            let context = ToolInvocationContext(RunId("scope-only"), thread, productCapabilities(),
                epoch: 1, toolContext: productToolContext(fixture.files.workspace))
            let config = lifecycleTestRequire(loadPluginLifecycleConfiguration(fixture.files.settings,
                productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)),
                productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Root))))
            let started = lifecycleTestRequire(manager.startProtocol(fixture.product.vnext, context,
                ThreadId("managed-late-ack-maintenance"), config, "stdio", "session",
                fixture.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))),
                ApprovalDecision.Approve))
            @Expect(!managedCompleted(Result.Ok(started.outcome)).isError)
            let budget = ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1, maxChildren: 4,
                maxTotalInputTokens: 2, maxTotalOutputTokens: 2, maxCostMicros: 2)
            let launch = shellManagedLaunch(fixture, thread.value, "late-ack",
                "printf ready > late-ack-ready; while :; do sleep 0.01; done; printf forbidden > late-ack-after", budget: budget)
            @Expect(!launch.isError)
            let id = lifecycleText(launch.output, "job_id")
            let run = lifecycleText(launch.output, "run_id")
            shellManagedWaitFile(fixture.files.workspace + "/late-ack-ready")
            shellManagedWaitWriteReceipt(fixture, run)
            let _ = runtime.cancelJobs(thread, [id])
            let deadline = MonoTime.now() + Duration.second * 10
            var ready = false
            while (!ready && MonoTime.now() < deadline) {
                let state = observedManagedAckJob(runtime, thread, id)
                ready = state.status == "recovery_required" && actualAck.load()
                if (!ready) { sleep(Duration.millisecond * 5) }
            }
            @Expect(ready)
            @Expect(actualAck.load())
            let withheld = observedManagedAckJob(runtime, thread, id)
            @Expect(withheld.status, "recovery_required")
            @Expect(withheld.executing)
            @Expect(shellManagedRootReceipt(fixture, run), "unknown")
            @Expect(fixture.childReceipts(), 1)
            @Expect(budget.remainingCumulativeBudget().inputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().outputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().costMicros, 1)
            for (_ in 0..3) {
                let unchanged = observedManagedAckJob(runtime, thread, id)
                @Expect(unchanged.executing)
                @Expect(unchanged.status, "recovery_required")
                @Expect(unchanged.updatedAt, withheld.updatedAt)
            }
            allowAck.store(true)
            let released = observedManagedAckJob(runtime, thread, id)
            @Expect(!released.executing)
            @Expect(released.status, "recovery_required")
            @Expect(released.updatedAt >= withheld.updatedAt)
            @Expect(released.error, withheld.error)
            for (_ in 0..3) {
                let unchanged = observedManagedAckJob(runtime, thread, id)
                @Expect(!unchanged.executing)
                @Expect(unchanged.status, "recovery_required")
                @Expect(unchanged.updatedAt, released.updatedAt)
            }
            @Expect(budget.remainingCumulativeBudget().inputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().outputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().costMicros, 1)
            @Expect(shellManagedRootReceipt(fixture, run), "unknown")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(!exists(Path(fixture.files.workspace + "/late-ack-after")))
        } finally {
            allowAck.store(true)
            try {
                let deadline = MonoTime.now() + Duration.second * 10
                var closed = false
                while (!closed && MonoTime.now() < deadline) {
                    closed = runtime.close().isOk()
                    if (!closed) { sleep(Duration.millisecond * 5) }
                }
                if (!closed) { throw IllegalStateException("actual managed Task cleanup did not acknowledge") }
            } finally {
                try {
                    match (retained) {
                        case Some(manager) => lifecycleTestRequire(manager.close())
                        case None => ()
                    }
                } finally {
                    try { lifecycleTestRequire(port.close()) } finally { fixture.close() }
                }
            }
        }
    }
}
