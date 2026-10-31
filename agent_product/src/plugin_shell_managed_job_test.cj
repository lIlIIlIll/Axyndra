package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Test-only metadata diagnostics; command text and output streams are not printed.
func shellDiagnosticFacts(f: ShellServiceProductFixture, label: String): Unit {
    println("SHELL_DIAGNOSTIC " + label)
    for (query in ["SELECT id,state FROM runs ORDER BY rowid",
        "SELECT o.id,o.state,COALESCE(e.tool_id,'') FROM operations o LEFT JOIN operation_effect_records e ON e.operation_id=o.id ORDER BY o.rowid",
        "SELECT operation_id,outcome FROM operation_receipts ORDER BY rowid",
        "SELECT operation_id,decision FROM approvals ORDER BY rowid"]) {
        let rows = f.database.query(query)
        println("SHELL_DIAGNOSTIC count=" + rows.size.toString())
        for (index in 0..min(rows.size, 32)) {
            let row = rows[index]; var line = ""
            for (column in 0..row.size) { line += " " + row.required(column) }
            println("SHELL_DIAGNOSTIC row" + line)
        }
    }
}
func shellDiagnosticTool(f: ShellServiceProductFixture, label: String,
    result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
    match (result) {
        case Result.Err(error) => println("SHELL_DIAGNOSTIC " + label + " Err code=" + error.code)
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            println("SHELL_DIAGNOSTIC " + label + " Completed isError=" + value.isError.toString() +
                " code=" + httpIntentText(value.output, "error") + " schema=" + httpIntentText(value.output, "schema"))
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => println("SHELL_DIAGNOSTIC " + label + " NeedsApproval " + value.toolName)
        case Result.Ok(ToolInvocationResult.Denied(_)) => println("SHELL_DIAGNOSTIC " + label + " Denied")
    }
    shellDiagnosticFacts(f, label)
    result
}
func shellDiagnosticApp(f: ShellServiceProductFixture, label: String,
    result: Result<ApplicationResponse>): Result<ApplicationResponse> {
    match (result) {
        case Result.Err(error) => println("SHELL_DIAGNOSTIC " + label + " Err code=" + error.code)
        case Result.Ok(value) =>
            let state = match (value.snapshot) { case Some(s) => runStateName(s.status); case None => "None" }
            let tool = match (value.approval) { case Some(a) => a.toolName; case None => "None" }
            println("SHELL_DIAGNOSTIC " + label + " Ok state=" + state + " approval=" + tool)
    }
    shellDiagnosticFacts(f, label)
    result
}

// Actual installed native Shell, packaged Python/Bash, sandbox, Task journal,
// canonical Direct/Committed parent, child Task Run and SQLite Receipts.
func shellManagedInput(command: String): AgentValue {
    objectValue([ValueField("command", textValue(command)), ValueField("async", boolValue(true))])
}

func shellManagedLaunch(fixture: ShellServiceProductFixture, thread: String, call: String, command: String,
    capabilities!: CapabilitySet = productCapabilities(),
    budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1, maxChildren: 4)): ToolResult {
    managedCompleted(shellDiagnosticTool(fixture, "managed-launch",
        fixture.product.vnext.executeCanonicalTool(SessionId(thread), capabilities,
            ToolCall(call, fixture.name, shellManagedInput(command)), budget: budget)))
}

func shellManagedWaitFile(path: String): Unit {
    let deadline = MonoTime.now() + Duration.second * 8
    while (!exists(Path(path)) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
    if (!exists(Path(path))) { throw IllegalStateException("actual background Bash did not reach the file barrier") }
}

func shellManagedJob(fixture: ShellServiceProductFixture, thread: String, id: String): ProductAsyncJobSnapshot {
    for (job in fixture.product.asyncJobs(SessionId(thread)) where job.id == id) { return job }
    throw IllegalStateException("actual Task journal has no managed job")
}

func shellManagedWait(fixture: ShellServiceProductFixture, thread: String, id: String): ProductAsyncJobSnapshot {
    let deadline = MonoTime.now() + Duration.second * 10
    while (MonoTime.now() < deadline) {
        let job = shellManagedJob(fixture, thread, id)
        if (job.status != "running" && !job.executing) { return job }
        sleep(Duration.millisecond * 5)
    }
    let last = shellManagedJob(fixture, thread, id)
    // Diagnostic only: fixed status categories and booleans, never job input,
    // result, paths, command bytes, endpoint identities or credential values.
    println("MANAGED_ACK_DIAGNOSTIC recovery_required=" + (last.status == "recovery_required").toString() +
        " running=" + (last.status == "running").toString() + " executing=" + last.executing.toString())
    var serviceSeen = false
    for (service in fixture.product.pluginServiceStatuses()) {
        serviceSeen = true
        let acknowledgement = service.field("cleanup_acknowledged")
        let valid = acknowledgement.isSome() && acknowledgement.getOrThrow().unifiedKind == ValueKind.Boolean
        println("MANAGED_ACK_DIAGNOSTIC service_ack_valid=" + valid.toString() +
            " cleanup_acknowledged=" + (valid && acknowledgement.getOrThrow().asBool()).toString())
    }
    println("MANAGED_ACK_DIAGNOSTIC service_seen=" + serviceSeen.toString())
    throw IllegalStateException("managed job retained " + last.status + ": " + last.error)
}

func shellManagedRunState(fixture: ShellServiceProductFixture, run: String): String {
    fixture.database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(run)])[0].required(0)
}

func shellManagedRootReceipt(fixture: ShellServiceProductFixture, run: String): String {
    let rows = fixture.database.query("SELECT r.outcome FROM operations o JOIN operation_receipts r ON r.operation_id=o.id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.run_id=? AND e.tool_id=?",
        [SqlParameter.Text(run), SqlParameter.Text(fixture.name)])
    if (rows.size != 1) { throw IllegalStateException("managed Task needs one actual root Receipt") }
    rows[0].required(0)
}

// Readiness on disk precedes the durable acknowledgement. Bind this barrier
// to the exact Task Run so another job or the startup receipt cannot satisfy it.
func shellManagedWaitWriteReceipt(fixture: ShellServiceProductFixture, run: String): Unit {
    let count = { => fixture.database.query("SELECT r.id FROM operation_receipts r " +
        "JOIN operations o ON o.id=r.operation_id JOIN operation_effect_records e ON e.operation_id=o.id " +
        "WHERE o.run_id=? AND e.tool_id=? AND r.outcome='completed'",
        [SqlParameter.Text(run), SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)]).size }
    let deadline = MonoTime.now() + Duration.second * 8
    while (count() == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    if (count() != 1) { throw IllegalStateException("exact Task write receipt did not acknowledge before revocation") }
}

@Test
class PluginShellManagedJobTests {
    @TestCase
    func completedDirectParentKeepsExactApprovedTaskAliveAndPersistsOneExecution(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true)
        try {
            @Expect(!managedCompleted(fixture.start("managed-parent")).isError)
            let budget = ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1, maxChildren: 4,
                maxTotalInputTokens: 2, maxTotalOutputTokens: 2, maxCostMicros: 2)
            let launch = shellManagedLaunch(fixture, "managed-parent", "same-call",
                "printf ready > task-ready; while [ ! -f task-release ]; do sleep 0.01; done; printf done > task-effect; printf child-result", budget: budget)
            @Expect(!launch.isError)
            @Expect(lifecycleText(launch.output, "schema"), "axyndra.managed-job-started/v1")
            let id = lifecycleText(launch.output, "job_id")
            let childRun = lifecycleText(launch.output, "run_id")
            let childThread = lifecycleText(launch.output, "thread_id")
            shellManagedWaitFile(fixture.files.workspace + "/task-ready")
            let running = shellManagedJob(fixture, "managed-parent", id)
            @Expect(running.jobType, "managed")
            @Expect(running.status, "running")
            @Expect(running.executing)
            @Expect(budget.remainingCumulativeBudget().inputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().costMicros, 1)
            @Expect(running.agentId, childRun)
            @Expect(running.ownerRunId.value != childRun && childThread != "managed-parent")
            @Expect(shellManagedRunState(fixture, running.ownerRunId.value), "completed")
            @Expect(shellManagedRootReceipt(fixture, running.ownerRunId.value), "completed")
            @Expect(!exists(Path(fixture.files.workspace + "/task-effect")))
            @Expect(fixture.database.query("SELECT id FROM items WHERE thread_id=? AND kind='system_note'", [SqlParameter.Text(childThread)]).size, 1)
            @Expect(fixture.database.query("SELECT id FROM items WHERE thread_id=? AND kind='user_message'", [SqlParameter.Text(childThread)]).size, 0)
            let plans = fixture.database.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id " +
                "WHERE e.tool_id=? AND o.run_id IN (?,?)", [SqlParameter.Text(fixture.name),
                    SqlParameter.Text(running.ownerRunId.value), SqlParameter.Text(childRun)])
            @Expect(plans.size, 2)
            @Expect(plans[0].required(0), plans[1].required(0))
            File.writeTo(fixture.files.workspace + "/task-release", "release".toArray())
            let completed = shellManagedWait(fixture, "managed-parent", id)
            @Expect(completed.status, "completed")
            @Expect(budget.remainingCumulativeBudget().inputTokens, 2)
            @Expect(budget.remainingCumulativeBudget().outputTokens, 2)
            @Expect(budget.remainingCumulativeBudget().costMicros, 2)
            @Expect(shellManagedRunState(fixture, childRun), "completed")
            @Expect(shellManagedRootReceipt(fixture, childRun), "completed")
            @Expect(lifecycleText(completed.result.getOrThrow().field("result").getOrThrow(), "stdout"), "child-result")
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/task-effect")), "done")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 1)
            @Expect(!managedCompleted(fixture.call("managed-parent", "ordinary-next", fixture.input("printf still-live"))).isError)
        } finally { fixture.close() }
    }

    @TestCase
    func committedApprovalRejectsZeroJobsThenDelegatesExactPlanWithoutSecondApproval(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true, approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("managed-approval")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("managed-approval")))
            session.setThinking(ThinkingLevel.Off)
            let input = shellManagedInput("printf ready > approved-ready; while [ ! -f approved-release ]; do sleep 0.01; done; printf approved > approved-effect")
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("reject-managed", fixture.name, input)
            lifecycleTestRequire(shellDiagnosticApp(fixture, "managed-submit", session.submit("Reject this background write.")))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.product.asyncJobs(SessionId("managed-approval")).isEmpty())
            @Expect(fixture.childReceipts(), 0)
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.product.asyncJobs(SessionId("managed-approval")).isEmpty())
            @Expect(!exists(Path(fixture.files.workspace + "/approved-ready")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("approve-managed", fixture.name, input)
            lifecycleTestRequire(shellDiagnosticApp(fixture, "managed-submit", session.submit("Approve the exact frozen background write.")))
            let approved = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approved.operationId.value)])[0].required(0)
            let approvalCount = fixture.database.scalarInt("SELECT COUNT(*) FROM approvals")
            lifecycleTestRequire(session.decide(approved.operationId.value, ApprovalDecision.Approve))
            let actualApproval = fixture.database.query("SELECT decision FROM approvals WHERE operation_id=?",
                [SqlParameter.Text(approved.operationId.value)])
            @Expect(actualApproval.size, 1)
            @Expect(actualApproval[0].required(0), "approved")
            let launch = mcpProductOutput(fixture.database, "managed-approval", "approve-managed")
            @Expect(lifecycleText(launch, "schema"), "axyndra.managed-job-started/v1")
            shellManagedWaitFile(fixture.files.workspace + "/approved-ready")
            @Expect(session.approval().isNone())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), approvalCount + 1)
            @Expect(fixture.database.query("SELECT a.operation_id FROM approvals a JOIN operations o ON o.id=a.operation_id " +
                "WHERE o.run_id=?", [SqlParameter.Text(lifecycleText(launch, "run_id"))]).isEmpty())
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approved.operationId.value)])[0].required(0), frozen)
            let child = fixture.database.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id " +
                "WHERE o.run_id=? AND e.tool_id=?", [SqlParameter.Text(lifecycleText(launch, "run_id")), SqlParameter.Text(fixture.name)])
            @Expect(child.size, 1)
            @Expect(child[0].required(0), frozen)
            File.writeTo(fixture.files.workspace + "/approved-release", "release".toArray())
            @Expect(shellManagedWait(fixture, "managed-approval", lifecycleText(launch, "job_id")).status, "completed")
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/approved-effect")), "approved")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), approvalCount + 1)
            @Expect(fixture.database.query("SELECT a.operation_id FROM approvals a JOIN operations o ON o.id=a.operation_id " +
                "WHERE o.run_id=?", [SqlParameter.Text(lifecycleText(launch, "run_id"))]).isEmpty())
        } finally { fixture.close() }
    }

    @TestCase
    func missingDelegateWrongThreadAndDefaultDisabledCannotLaunchBackendCommand(): Unit {
        let enabled = ShellServiceProductFixture(asyncEnabled: true)
        try {
            @Expect(!managedCompleted(enabled.start("managed-capability")).isError)
            let limited = ArrayList<Capability>()
            for (value in productCapabilities().values where value.kind != CapabilityKind.Delegate) { limited.add(value) }
            let refused = enabled.product.vnext.executeCanonicalTool(SessionId("managed-capability"), CapabilitySet(values: limited.toArray()),
                ToolCall("no-delegate", enabled.name, shellManagedInput("printf forbidden > forbidden")),
                budget: ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1))
            let _ = shellDiagnosticTool(enabled, "no-delegate", refused)
            // The service was bound to a larger capability domain at startup.
            // Changing it at invocation is a stale identity, not a Delegate grant.
            @Expect(match (refused) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    value.isError && lifecycleText(value.output, "error") == "plugin.lifecycle_invocation_stale"
                case _ => false
            })
            @Expect(!enabled.visible("other-thread"))
            let wrong = enabled.product.vnext.executeCanonicalTool(SessionId("other-thread"), productCapabilities(),
                ToolCall("wrong-thread", enabled.name, shellManagedInput("printf forbidden > forbidden")))
            match (wrong) { case Result.Ok(ToolInvocationResult.Completed(value)) => @Expect(value.isError)
                case Result.Err(_) => (); case Result.Ok(ToolInvocationResult.Denied(_)) => (); case _ => @Expect(false) }
            @Expect(enabled.product.asyncJobs(SessionId("managed-capability")).isEmpty())
            @Expect(enabled.product.asyncJobs(SessionId("other-thread")).isEmpty())
            @Expect(enabled.childReceipts(), 0)
            @Expect(!exists(Path(enabled.files.workspace + "/forbidden")))
        } finally { enabled.close() }
        // Bind the actual startup and invocation to the same limited domain.
        // The callback is only a tripwire: policy must reject before it runs.
        let limitedFixture = ShellServiceProductFixture(asyncEnabled: true)
        let port = LocalProcessPort(LocalWorkspace(limitedFixture.files.workspace), sandboxEnabled: true)
        var retained: ?ProductPluginLifecycleManager = None
        try {
            let calls = AtomicInt64(0)
            let launcher: ProductManagedJobLauncher = { _, _, _ =>
                calls.fetchAdd(1)
                lifecycleLeaseError<ToolResult>("fixture.launcher_must_not_run")
            }
            let manager = lifecycleTestRequire(limitedFixture.product.vnext.createPluginLifecycleManager(port,
                managedJobLauncher: Some(launcher)))
            retained = Some(manager)
            let values = ArrayList<Capability>()
            for (value in productCapabilities().values where value.kind != CapabilityKind.Delegate) { values.add(value) }
            let ceiling = CapabilitySet(values: values.toArray())
            let context = ToolInvocationContext(RunId("scope-only"), SessionId("never-delegated"), ceiling,
                epoch: 1, toolContext: productToolContext(limitedFixture.files.workspace))
            let config = lifecycleTestRequire(loadPluginLifecycleConfiguration(limitedFixture.files.settings,
                productRegistryCopyText83(limitedFixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(limitedFixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)),
                productRegistryCopyText83(limitedFixture.record.descriptor.copyText(PluginDescriptorText.Root))))
            let started = lifecycleTestRequire(manager.startProtocol(limitedFixture.product.vnext, context,
                ThreadId("never-delegated-maintenance"), config, "stdio", "session",
                limitedFixture.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(limitedFixture.record.descriptor.copyText(PluginDescriptorText.Namespace))),
                ApprovalDecision.Approve))
            @Expect(!managedCompleted(Result.Ok(started.outcome)).isError)
            @Expect(limitedFixture.visible("never-delegated"))
            @Expect(limitedFixture.childReceipts(), 0)
            let refused = limitedFixture.product.vnext.executeCanonicalTool(SessionId("never-delegated"), ceiling,
                ToolCall("missing-delegate", limitedFixture.name, shellManagedInput("printf forbidden > forbidden")),
                budget: ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1))
            let _ = shellDiagnosticTool(limitedFixture, "startup-without-delegate", refused)
            @Expect(match (refused) {
                case Result.Ok(ToolInvocationResult.Denied(value)) => value.reason.code == "tool.capability_denied"
                case _ => false
            })
            @Expect(calls.load(), 0)
            @Expect(limitedFixture.product.asyncJobs(SessionId("never-delegated")).isEmpty())
            @Expect(limitedFixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 0)
            @Expect(limitedFixture.childReceipts(), 0)
            @Expect(!exists(Path(limitedFixture.files.workspace + "/forbidden")))
        } finally {
            try {
                match (retained) {
                    case Some(manager) =>
                        let deadline = MonoTime.now() + Duration.second * 8
                        var released = false
                        while (!released && MonoTime.now() < deadline) {
                            released = manager.close().isOk()
                            if (!released) { sleep(Duration.millisecond * 10) }
                        }
                        if (!released) { throw IllegalStateException("limited Shell manager retains cleanup ownership") }
                    case None => ()
                }
            } finally {
                try { lifecycleTestRequire(port.close()) } finally { limitedFixture.close() }
            }
        }
        let disabled = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(disabled.start("managed-disabled")).isError)
            let refused = disabled.product.vnext.executeCanonicalTool(SessionId("managed-disabled"), productCapabilities(),
                ToolCall("disabled", disabled.name, shellManagedInput("printf forbidden > forbidden")),
                budget: ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1))
            let _ = shellDiagnosticTool(disabled, "disabled", refused)
            @Expect(match (refused) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    value.isError && lifecycleText(value.output, "error") == "task.managed_job_denied"
                case _ => false
            })
            let roots = disabled.database.query("SELECT o.state,r.outcome FROM operations o " +
                "JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN operation_receipts r ON r.operation_id=o.id WHERE e.tool_id=?",
                [SqlParameter.Text(disabled.name)])
            @Expect(roots.size, 1)
            @Expect(roots[0].required(0), "committed")
            @Expect(roots[0].required(1), "failed")
            @Expect(disabled.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 0)
            @Expect(disabled.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing','recovery_required')"), 0)
            @Expect(disabled.product.asyncJobs(SessionId("managed-disabled")).isEmpty())
            @Expect(disabled.childReceipts(), 0)
            @Expect(!exists(Path(disabled.files.workspace + "/forbidden")))
        } finally { disabled.close() }
    }

    @TestCase
    func cancelAfterParentCompletionKillsActualDescendantsAndCannotReplayUnknown(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true)
        try {
            @Expect(!managedCompleted(fixture.start("managed-cancel")).isError)
            let budget = ExecutionBudget(maxToolCalls: 16, maxConcurrentTools: 1, maxChildren: 4,
                maxTotalInputTokens: 2, maxTotalOutputTokens: 2, maxCostMicros: 2)
            let launch = shellManagedLaunch(fixture, "managed-cancel", "cancel",
                "(while :; do printf x >> heartbeat; sleep 0.02; done) & printf ready > cancel-ready; wait; printf forbidden > after-cancel", budget: budget)
            @Expect(!launch.isError)
            let id = lifecycleText(launch.output, "job_id")
            let run = lifecycleText(launch.output, "run_id")
            shellManagedWaitFile(fixture.files.workspace + "/cancel-ready")
            shellManagedWaitFile(fixture.files.workspace + "/heartbeat")
            let job = shellManagedJob(fixture, "managed-cancel", id)
            @Expect(shellManagedRunState(fixture, job.ownerRunId.value), "completed")
            shellManagedWaitWriteReceipt(fixture, run)
            let _ = fixture.product.cancelAsyncJobs(SessionId("managed-cancel"), [id])
            let cancelled = shellManagedWait(fixture, "managed-cancel", id)
            @Expect(cancelled.status, "recovery_required")
            @Expect(shellManagedRootReceipt(fixture, run), "unknown")
            // The exact command bytes were already acknowledged before Bash
            // blocked. Cancellation must not relabel that write or resend it.
            @Expect(fixture.childReceipts(), 1)
            fixture.waitReleased()
            @Expect(budget.remainingCumulativeBudget().inputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().outputTokens, 1)
            @Expect(budget.remainingCumulativeBudget().costMicros, 1)
            let heartbeat = File.readFrom(fixture.files.workspace + "/heartbeat")
            sleep(Duration.millisecond * 120)
            @Expect(File.readFrom(fixture.files.workspace + "/heartbeat").size, heartbeat.size)
            @Expect(!exists(Path(fixture.files.workspace + "/after-cancel")))
            @Expect(!fixture.visible("managed-cancel"))
            let _ = fixture.product.cancelAsyncJobs(SessionId("managed-cancel"), [id])
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func disabledGenerationAndReopenedTaskJournalCannotResumeOrReplayTheCommand(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true)
        try {
            @Expect(!managedCompleted(fixture.start("managed-disable")).isError)
            let launch = shellManagedLaunch(fixture, "managed-disable", "disable",
                "printf ready > disabled-ready; while [ ! -f disabled-release ]; do sleep 0.01; done; printf forbidden > disabled-effect")
            @Expect(!launch.isError)
            let id = lifecycleText(launch.output, "job_id")
            shellManagedWaitFile(fixture.files.workspace + "/disabled-ready")
            shellManagedWaitWriteReceipt(fixture, lifecycleText(launch.output, "run_id"))
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            @Expect(shellManagedWait(fixture, "managed-disable", id).status, "recovery_required")
            @Expect(!fixture.visible("managed-disable"))
            fixture.waitReleased()
            @Expect(shellManagedRootReceipt(fixture, lifecycleText(launch.output, "run_id")), "unknown")
            @Expect(fixture.childReceipts(), 1)
            lifecycleTestRequire(fixture.product.close())
            File.writeTo(fixture.files.workspace + "/disabled-release", "late release".toArray())
            let reopened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: fixture.files.workspace,
                settingsRoot: fixture.files.settings, stateRoot: fixture.files.root + "/state", fixture: true, asyncEnabled: true)))
            try {
                let jobs = reopened.asyncJobs(SessionId("managed-disable"))
                @Expect(jobs.size, 1)
                @Expect(jobs[0].id, id)
                @Expect(jobs[0].status, "recovery_required")
                @Expect(!jobs[0].executing)
                @Expect(!exists(Path(fixture.files.workspace + "/disabled-effect")))
                @Expect(fixture.childReceipts(), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            } finally { lifecycleTestRequire(reopened.close()) }
        } finally { fixture.close() }
    }

    @TestCase
    func sameCallIdAcrossThreadsKeepsIndependentTaskCancellationAndServiceLease(): Unit {
        let fixture = ShellServiceProductFixture(asyncEnabled: true)
        try {
            @Expect(!managedCompleted(fixture.start("managed-a")).isError)
            @Expect(!managedCompleted(fixture.start("managed-b")).isError)
            let a = shellManagedLaunch(fixture, "managed-a", "same",
                "printf ready > a-ready; while [ ! -f a-release ]; do sleep 0.01; done; printf wrong > a-effect")
            let b = shellManagedLaunch(fixture, "managed-b", "same",
                "printf ready > b-ready; while [ ! -f b-release ]; do sleep 0.01; done; printf isolated > b-effect")
            @Expect(!a.isError && !b.isError)
            shellManagedWaitFile(fixture.files.workspace + "/a-ready")
            shellManagedWaitFile(fixture.files.workspace + "/b-ready")
            let aId = lifecycleText(a.output, "job_id"); let bId = lifecycleText(b.output, "job_id")
            @Expect(aId != bId)
            @Expect(lifecycleText(a.output, "thread_id") != lifecycleText(b.output, "thread_id"))
            let _ = fixture.product.cancelAsyncJobs(SessionId("managed-a"), [aId])
            @Expect(shellManagedWait(fixture, "managed-a", aId).status, "recovery_required")
            @Expect(fixture.visible("managed-b"))
            @Expect(shellManagedJob(fixture, "managed-b", bId).status, "running")
            File.writeTo(fixture.files.workspace + "/b-release", "release".toArray())
            @Expect(shellManagedWait(fixture, "managed-b", bId).status, "completed")
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/b-effect")), "isolated")
            @Expect(!exists(Path(fixture.files.workspace + "/a-effect")))
            @Expect(fixture.childReceipts(), 2)
            @Expect(shellManagedRootReceipt(fixture, lifecycleText(a.output, "run_id")), "unknown")
            @Expect(shellManagedRootReceipt(fixture, lifecycleText(b.output, "run_id")), "completed")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }
}
