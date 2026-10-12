package agent_product

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Delegate every real launch/cleanup to the production sandbox. The counter
// observes whether rejected canonical calls ever cross the process boundary.
class LifecycleControlProcessProbe <: ProcessPort {
    let port: LocalProcessPort
    var opens: Int64 = 0
    var operation: ?OperationId = None
    init(workspace: String) { port = LocalProcessPort(LocalWorkspace(workspace), sandboxEnabled: true) }
    public func execute(request: ProcessRequest): Result<ProcessResult> { port.execute(request) }
    public func reserveOperation(operationId: OperationId): Unit { port.reserveOperation(operationId) }
    public func releaseOperation(operationId: OperationId): Unit { port.releaseOperation(operationId) }
    public func cancel(operationId: OperationId): Result<Unit> { port.cancel(operationId) }
    public func openChannel(request: ProcessRequest, cancellation: CancellationToken,
        maxInputBytes: Int64): Result<ProcessChannel> {
        opens += 1; operation = Some(request.operationId)
        port.openChannel(request, cancellation, maxInputBytes)
    }
    public func closeChannelOperation(operationId: OperationId): Result<Unit> { port.closeChannelOperation(operationId) }
}

class LifecycleControlFixture {
    let configuration = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let database: SqliteDatabase
    let processes: LifecycleControlProcessProbe
    let owner: ProductPluginLifecycleOwner
    let control: ProductPluginLifecycleControl
    let grant: ProductPluginLifecycleLaunchGrant
    init() {
        let service = configuration.service()
        service.put("executable", textValue("/usr/bin/cat"))
        service.put("arguments", listValue([]))
        service.put("lifetime_ms", integerValue(30000))
        service.field("startup").getOrThrow().put("timeout_ms", integerValue(5000))
        configuration.write(configuration.document(service: Some(service)))
        // This context only computes an isolation key; no Run or authority is
        // minted here. The actual maintenance Run is admitted by the control.
        let scope = pluginInvocationAuthorityScope(ToolInvocationContext(RunId("scope-only"), SessionId("target-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)]), epoch: 1,
            toolContext: productToolContext(configuration.workspace)))
        grant = lifecycleTestRequire(lifecycleTestRequire(configuration.load()).bindService("stdio",
            ThreadId("target-thread"), "host-minted-instance", configuration.workspace, ExecutionResourceLimits(), scope))
        product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: configuration.workspace,
            settingsRoot: configuration.settings, stateRoot: configuration.root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
        database = SqliteDatabase(configuration.root + "/state/state.db")
        processes = LifecycleControlProcessProbe(configuration.workspace)
        owner = ProductPluginLifecycleOwner(database, processes)
        control = ProductPluginLifecycleControl(owner)
        lifecycleTestRequire(product.registerTool(control.descriptor(), control))
    }
    func ceiling(): CapabilitySet {
        CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)])
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        var stopped = false
        while (!stopped && MonoTime.now() < deadline) {
            stopped = owner.close().isOk()
            if (!stopped) { sleep(Duration.millisecond * 5) }
        }
        let portClosed = processes.port.close()
        let _ = product.close()
        database.close()
        if (!stopped || portClosed.isError()) { throw IllegalStateException("lifecycle control fixture retains cleanup ownership") }
        configuration.close()
    }
}

func lifecycleControlEcho(lease: ProductPluginLifecycleLease, message: String): AgentValue {
    lifecycleTestRequire(lease.startupWrite(message.toArray()))
    var output = ""
    let deadline = MonoTime.now() + Duration.second * 3
    while (output.size < message.size && MonoTime.now() < deadline) {
        let received = lifecycleTestRequire(lease.startupRead(ProcessChannelStream.Stdout, 4096, 25))
        output += String.fromUtf8(received.bytes)
        if (received.eof) { break }
    }
    if (output != message) { throw IllegalStateException("real sandbox channel did not echo startup bytes") }
    objectValue([ValueField("echo", textValue(output))])
}

class LifecycleControlLeaseCapture { var value: ?ProductPluginLifecycleLease = None }

@Test
class ProductPluginLifecycleControlTests {
    @TestCase
    func approvedStartupCommitsOnceThenRetainsBoundedOwnerWithoutKeepingRunOpen(): Unit {
        let fixture = LifecycleControlFixture()
        try {
            let earlyActivationRefused = AtomicBool(false)
            let launched = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                SessionId("lifecycle-maintenance-approved"), fixture.grant, fixture.ceiling(),
                { lease, _, _ =>
                    earlyActivationRefused.store(fixture.owner.activate(lease).isError())
                    Result.Ok(lifecycleControlEcho(lease, "actual-startup-echo\n"))
                }, approvalDecision: Some(ApprovalDecision.Approve)))
            let lease = launched.lease.getOrThrow()
            @Expect(earlyActivationRefused.load())
            @Expect(fixture.processes.opens, 1)
            @Expect(fixture.processes.port.hasActiveOperation(fixture.processes.operation.getOrThrow()))
            @Expect(lease.startupWrite("forbidden-after-commit".toArray()).isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals WHERE decision='approved'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_host_origin_bound'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='running'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let result = match (launched.outcome) {
                case ToolInvocationResult.Completed(value) => value
                case _ => throw IllegalStateException("approved startup has no result")
            }
            @Expect(result.output.field("lease_id").getOrThrow().text, lease.leaseId)
            @Expect(result.output.field("launch_digest").getOrThrow().text, fixture.grant.digest)
            @Expect(result.output.field("result").getOrThrow().field("echo").getOrThrow().text, "actual-startup-echo\n")
        } finally { fixture.close() }
    }

    @TestCase
    func configurationAndOriginCannotSubstituteForCapabilitiesApprovalOrHostAdmission(): Unit {
        let fixture = LifecycleControlFixture()
        try {
            let callbacks = AtomicInt64(0)
            let action: ProductPluginLifecycleStartup = { _, _, _ => let _ = callbacks.fetchAdd(1); Result.Ok(objectValue([])) }
            let unapproved = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                SessionId("lifecycle-unapproved"), fixture.grant, fixture.ceiling(), action))
            @Expect(match (unapproved.outcome) { case ToolInvocationResult.NeedsApproval(_) => true; case _ => false })
            let rejected = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                SessionId("lifecycle-rejected"), fixture.grant, fixture.ceiling(), action,
                approvalDecision: Some(ApprovalDecision.Reject)))
            @Expect(rejected.lease.isNone())
            let noCapability = fixture.control.launch(fixture.product.vnext, SessionId("lifecycle-no-capability"),
                fixture.grant, CapabilitySet(values: []), action, approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(match (noCapability) { case Result.Ok(value) => value.lease.isNone(); case Result.Err(_) => true })
            let forged = fixture.product.vnext.executeCanonicalTool(SessionId("lifecycle-public-guess"),
                fixture.ceiling(), ToolCall("forged-host-call", PLUGIN_LIFECYCLE_TOOL, fixture.grant.launchPlan))
            @Expect(hostServiceEntryCompleted(forged).isError)
            @Expect(fixture.control.launch(fixture.product.vnext, SessionId(fixture.grant.targetThread.value),
                fixture.grant, fixture.ceiling(), action, approvalDecision: Some(ApprovalDecision.Approve)).isError())
            @Expect(callbacks.load(), 0)
            @Expect(fixture.processes.opens, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func approvalPreviewClosesItsRunWithoutAnOperationAndCanBeFollowedByAnApprovedLaunch(): Unit {
        let fixture = LifecycleControlFixture()
        try {
            let callbacks = AtomicInt64(0)
            let action: ProductPluginLifecycleStartup = { lease, _, _ =>
                let _ = callbacks.fetchAdd(1)
                Result.Ok(lifecycleControlEcho(lease, "approved-after-preview\n"))
            }
            let maintenance = SessionId("lifecycle-preview-then-approve")
            let preview = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                maintenance, fixture.grant, fixture.ceiling(), action))
            @Expect(match (preview.outcome) { case ToolInvocationResult.NeedsApproval(_) => true; case _ => false })
            @Expect(preview.lease.isNone())
            @Expect(callbacks.load(), 0)
            @Expect(fixture.processes.opens, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='running'"), 0)
            let approved = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                maintenance, fixture.grant, fixture.ceiling(), action, approvalDecision: Some(ApprovalDecision.Approve)))
            @Expect(approved.lease.isSome())
            @Expect(callbacks.load(), 1)
            @Expect(fixture.processes.opens, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='running'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func failureAfterActualStartupWriteClosesPendingLeaseAndKeepsUnknownReceipt(): Unit {
        let fixture = LifecycleControlFixture()
        try {
            let captured = LifecycleControlLeaseCapture()
            let attempted = fixture.control.launch(fixture.product.vnext, SessionId("lifecycle-startup-failed"),
                fixture.grant, fixture.ceiling(), { lease, _, _ =>
                    captured.value = Some(lease)
                    let _ = lifecycleControlEcho(lease, "sent-before-failure\n")
                    Result.Err(AgentError(AgentErrorKind.Transport, "fixture.startup_response_lost",
                        "fixture loses the result after an actual process write", retryable: false))
                }, approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(match (attempted) { case Result.Err(_) => true; case Result.Ok(value) => value.lease.isNone() })
            @Expect(fixture.processes.opens, 1)
            @Expect(captured.value.getOrThrow().startupWrite("never-retry".toArray()).isError())
            @Expect(fixture.owner.activate(captured.value.getOrThrow()).isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }
}
