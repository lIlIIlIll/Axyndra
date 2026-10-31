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

// Only cleanup acknowledgement is controllable. Launch, sandbox, pipes,
// cancellation and reaping always use the actual LocalProcessPort.
class LifecycleCleanupGate <: ProcessPort {
    let port: LocalProcessPort
    let acknowledge = AtomicBool(true)
    var opens: Int64 = 0
    init(workspace: String) { port = LocalProcessPort(LocalWorkspace(workspace), sandboxEnabled: true) }
    public func execute(request: ProcessRequest): Result<ProcessResult> { port.execute(request) }
    public func reserveOperation(operationId: OperationId): Unit { port.reserveOperation(operationId) }
    public func releaseOperation(operationId: OperationId): Unit { port.releaseOperation(operationId) }
    public func cancel(operationId: OperationId): Result<Unit> { port.cancel(operationId) }
    public func openChannel(request: ProcessRequest, cancellation: CancellationToken,
        maxInputBytes: Int64): Result<ProcessChannel> {
        opens += 1
        port.openChannel(request, cancellation, maxInputBytes)
    }
    public func closeChannelOperation(operationId: OperationId): Result<Unit> {
        if (!acknowledge.load()) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "fixture.cleanup_pending", "cleanup acknowledgement withheld"))
        }
        port.closeChannelOperation(operationId)
    }
}

class LifecycleOwnerFixture {
    let configuration = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let database: SqliteDatabase
    let processes: LifecycleCleanupGate
    let owner: ProductPluginLifecycleOwner
    let control: ProductPluginLifecycleControl
    let config: ProductPluginLifecycleConfiguration
    let permissionDomain: String
    init(lifetimeMillis!: Int64 = 30000, startupMillis!: Int64 = 5000, registerControl!: Bool = true) {
        let service = configuration.service()
        service.put("executable", textValue("/usr/bin/cat"))
        service.put("arguments", listValue([]))
        service.put("lifetime_ms", integerValue(lifetimeMillis))
        service.field("startup").getOrThrow().put("timeout_ms", integerValue(startupMillis))
        let document = configuration.document(service: Some(service))
        document.field("plugins").getOrThrow().items[0].put("max_instances", integerValue(1))
        configuration.write(document)
        config = lifecycleTestRequire(configuration.load())
        permissionDomain = pluginInvocationAuthorityScope(ToolInvocationContext(RunId("scope-only"), SessionId("target-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)]),
            epoch: 1, toolContext: productToolContext(configuration.workspace)))
        product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: configuration.workspace,
            settingsRoot: configuration.settings, stateRoot: configuration.root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
        database = SqliteDatabase(configuration.root + "/state/state.db")
        processes = LifecycleCleanupGate(configuration.workspace)
        owner = ProductPluginLifecycleOwner(database, processes, operations: product.vnext.operations)
        control = ProductPluginLifecycleControl(owner)
        if (registerControl) { lifecycleTestRequire(product.registerTool(control.descriptor(), control)) }
    }
    func ceiling(): CapabilitySet { CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)]) }
    func grant(instance: String): ProductPluginLifecycleLaunchGrant {
        lifecycleTestRequire(config.bindService("stdio", ThreadId("target-thread"), instance,
            configuration.workspace, ExecutionResourceLimits(), permissionDomain,
            registryAdmission: Some(configuration.registryAdmission())))
    }
    func launch(instance: String, thread: String): ProductPluginLifecycleLease {
        let result = lifecycleTestRequire(control.launch(product.vnext, SessionId(thread), grant(instance), ceiling(),
            { lease, _, _ => Result.Ok(lifecycleControlEcho(lease, "owner-actual-echo\n")) },
            approvalDecision: Some(ApprovalDecision.Approve)))
        result.lease.getOrThrow()
    }
    func close(): Unit {
        processes.acknowledge.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        var stopped = false
        while (!stopped && MonoTime.now() < deadline) {
            stopped = owner.close().isOk()
            if (!stopped) { sleep(Duration.millisecond * 5) }
        }
        let portClosed = processes.port.close()
        let _ = product.close()
        database.close()
        if (!stopped || portClosed.isError()) { throw IllegalStateException("lifecycle owner fixture retains actual resources") }
        configuration.close()
    }
}

class LifecycleOwnerCaptured {
    var lease: ?ProductPluginLifecycleLease = None
    var context: ?ToolInvocationContext = None
    var prepared: ?PreparedToolInvocation = None
}

func lifecycleOwnerWaitReleased(lease: ProductPluginLifecycleLease): Bool {
    let deadline = MonoTime.now() + Duration.second * 6
    while (!lease.resourcesReleased() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    lease.resourcesReleased()
}

@Test
class ProductPluginLifecycleOwnerTests {
    @TestCase
    func sameMountCanOwnDifferentThreadsButCannotDuplicateExactScope(): Unit {
        let fixture = LifecycleControlFixture()
        try {
            let first = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext, SessionId("first-scope-maintenance"),
                fixture.grant, fixture.ceiling(), { lease, _, _ => Result.Ok(lifecycleControlEcho(lease, "first-scope\n")) },
                approvalDecision: Some(ApprovalDecision.Approve))).lease.getOrThrow()
            let duplicate = fixture.control.launch(fixture.product.vnext, SessionId("duplicate-scope-maintenance"),
                fixture.grant, fixture.ceiling(), { _, _, _ => throw IllegalStateException("duplicate scope reached startup") },
                approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(duplicate.isError())
            @Expect(fixture.processes.opens, 1)
            let secondGrant = lifecycleTestRequire(lifecycleTestRequire(fixture.configuration.load()).bindService("stdio",
                ThreadId("other-target-thread"), fixture.grant.instanceIdentity, fixture.configuration.workspace,
                ExecutionResourceLimits(), lifecycleText(fixture.grant.launchPlan, "permission_domain"),
                registryAdmission: Some(fixture.configuration.registryAdmission())))
            let second = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext, SessionId("second-scope-maintenance"),
                secondGrant, fixture.ceiling(), { lease, _, _ => Result.Ok(lifecycleControlEcho(lease, "second-scope\n")) },
                approvalDecision: Some(ApprovalDecision.Approve))).lease.getOrThrow()
            @Expect(first.isActive() && second.isActive())
            @Expect(first.instanceIdentity, second.instanceIdentity)
            @Expect(first.leaseId != second.leaseId)
            @Expect(first.targetThread.value != second.targetThread.value)
            @Expect(fixture.processes.opens, 2)
            @Expect(fixture.owner.retainedCount(), 2)
        } finally { fixture.close() }
    }

    @TestCase
    func frozenLaunchCannotExceedActualParentResourceCeiling(): Unit {
        let fixture = LifecycleOwnerFixture()
        try {
            let result = fixture.control.launch(fixture.product.vnext, SessionId("bounded-maintenance"),
                fixture.grant("bounded-instance"), fixture.ceiling(),
                { _, _, _ => throw IllegalStateException("over-budget launch reached startup") },
                approvalDecision: Some(ApprovalDecision.Approve),
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1,
                    processLimits: ExecutionResourceLimits(maxOutputBytes: 1024)))
            @Expect(result.isError())
            @Expect(fixture.processes.opens, 0)
            @Expect(fixture.owner.retainedCount(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func activeLeaseRevokesOnConfigurationBytesChangeWithoutRewritingStartupFacts(): Unit {
        let fixture = LifecycleOwnerFixture()
        try {
            let lease = fixture.launch("configuration-instance", "configuration-maintenance")
            let staleGrant = fixture.grant("stale-instance")
            let revocationObserved = AtomicBool(false)
            let registration = lease.observeRevocation({ => revocationObserved.store(!lease.isActive()) })
            @Expect(lease.isActive())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            let path = fixture.configuration.settings + "/plugins/lifecycle.json"
            File.writeTo(path, (String.fromUtf8(File.readFrom(path)) + "\n").toArray())
            @Expect(lifecycleOwnerWaitReleased(lease))
            @Expect(!lease.isActive())
            @Expect(revocationObserved.load())
            registration.dispose()
            let immediate = AtomicBool(false)
            let afterClose = lease.observeRevocation({ => immediate.store(!lease.isActive()) })
            @Expect(immediate.load())
            afterClose.dispose()
            @Expect(!fixture.processes.port.hasActiveOperation(lease.operationId))
            @Expect(fixture.owner.retainedCount(), 0)
            @Expect(lease.startupWrite("late".toArray()).isError())
            @Expect(fixture.control.launch(fixture.product.vnext, SessionId("stale-configuration-maintenance"),
                staleGrant, fixture.ceiling(),
                { _, _, _ => Result.Ok(objectValue([])) }, approvalDecision: Some(ApprovalDecision.Approve)).isError())
            @Expect(fixture.processes.opens, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func finiteLeaseExpiresAfterStartupRunCompletesAndCannotReactivate(): Unit {
        let fixture = LifecycleOwnerFixture(lifetimeMillis: 4000, startupMillis: 2000)
        try {
            let lease = fixture.launch("expiry-instance", "expiry-maintenance")
            @Expect(lease.isActive())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='running'"), 0)
            @Expect(lifecycleOwnerWaitReleased(lease))
            @Expect(!fixture.processes.port.hasActiveOperation(lease.operationId))
            @Expect(fixture.owner.activate(lease).isError())
            @Expect(fixture.owner.retainedCount(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func failedCleanupAcknowledgementRetainsCapacityUntilActualPortRelease(): Unit {
        let fixture = LifecycleOwnerFixture()
        try {
            let lease = fixture.launch("retained-instance", "retained-maintenance")
            fixture.processes.acknowledge.store(false)
            @Expect(fixture.owner.revoke(lease).isError())
            @Expect(!lease.isActive() && !lease.resourcesReleased())
            @Expect(fixture.owner.retainedCount(), 1)
            let blocked = fixture.control.launch(fixture.product.vnext, SessionId("capacity-maintenance"),
                fixture.grant("blocked-instance"), fixture.ceiling(),
                { _, _, _ => Result.Ok(objectValue([])) }, approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(blocked.isError())
            @Expect(fixture.processes.opens, 1)
            @Expect(fixture.owner.retainedCount(), 1)
            fixture.processes.acknowledge.store(true)
            @Expect(lifecycleOwnerWaitReleased(lease))
            @Expect(!fixture.processes.port.hasActiveOperation(lease.operationId))
            let replacement = fixture.launch("replacement-instance", "replacement-maintenance")
            @Expect(replacement.isActive())
            @Expect(replacement.leaseId != lease.leaseId)
            @Expect(fixture.processes.opens, 2)
            @Expect(fixture.owner.retainedCount(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func actualStartupDeadlineAfterWriteRetainsUnknownAndClosesChannel(): Unit {
        let fixture = LifecycleOwnerFixture(startupMillis: 10000)
        let captured = LifecycleOwnerCaptured()
        try {
            let result = fixture.control.launch(fixture.product.vnext, SessionId("cancelled-maintenance"),
                fixture.grant("cancelled-instance"), fixture.ceiling(), { lease, context, _ =>
                    captured.lease = Some(lease)
                    let _ = lifecycleControlEcho(lease, "sent-before-deadline\n")
                    let deadline = MonoTime.now() + Duration.second * 6
                    while (!context.cancellation.isCancelled() && MonoTime.now() < deadline) {
                        sleep(Duration.millisecond * 5)
                    }
                    if (!context.cancellation.isCancelled() || lease.startupWrite("late".toArray()).isOk()) {
                        throw IllegalStateException("startup deadline did not fence actual write")
                    }
                    match (context.cancellation.check()) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(_) => throw IllegalStateException("cancelled startup lost cancellation evidence")
                    }
                }, approvalDecision: Some(ApprovalDecision.Approve),
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1, deadlineMillis: agentUtcMillis() + 4000))
            @Expect(result.isError())
            let lease = captured.lease.getOrThrow()
            @Expect(lifecycleOwnerWaitReleased(lease))
            @Expect(!fixture.processes.port.hasActiveOperation(lease.operationId))
            @Expect(fixture.owner.activate(lease).isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelled'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func activationProofRequiresExactCanonicalResultReceiptAndHostOriginEvidence(): Unit {
        let fixture = LifecycleOwnerFixture()
        let captured = LifecycleOwnerCaptured()
        try {
            let grant = fixture.grant("proof-instance")
            let launched = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                SessionId("proof-maintenance"), grant, fixture.ceiling(), { lease, context, prepared =>
                    captured.lease = Some(lease); captured.context = Some(context); captured.prepared = Some(prepared)
                    Result.Ok(lifecycleControlEcho(lease, "proof-echo\n"))
                }, approvalDecision: Some(ApprovalDecision.Approve)))
            let output = match (launched.outcome) {
                case ToolInvocationResult.Completed(value) => value.output
                case _ => throw IllegalStateException("actual startup failed")
            }
            let encoded = stringifyUnifiedJson(output)
            let context = captured.context.getOrThrow()
            let prepared = captured.prepared.getOrThrow()
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isOk())
            // A Completed Receipt is not enough while its maintenance Run is
            // still running. Retain all real canonical result/receipt bytes.
            fixture.database.execute("UPDATE runs SET state='running' WHERE id=?", [SqlParameter.Text(context.runId.value)])
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isError())
            fixture.database.execute("UPDATE runs SET state='completed' WHERE id=?", [SqlParameter.Text(context.runId.value)])
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isOk())
            output.put("lease_id", textValue("invented-lease"))
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant,
                stringifyUnifiedJson(output)).isError())
            let audit = fixture.database.query("SELECT id,payload FROM audit_events WHERE kind='operation_host_origin_bound'")[0]
            fixture.database.execute("UPDATE audit_events SET payload='tampered' WHERE id=?", [SqlParameter.Text(audit.required(0))])
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isError())
            fixture.database.execute("UPDATE audit_events SET payload=? WHERE id=?",
                [SqlParameter.Text(audit.required(1)), SqlParameter.Text(audit.required(0))])
            let receipt = fixture.database.query("SELECT id,detail FROM operation_receipts")[0]
            fixture.database.execute("UPDATE operation_receipts SET detail=? WHERE id=?", [
                SqlParameter.Text(encodeStoredValue(objectValue([]))), SqlParameter.Text(receipt.required(0))])
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isError())
            fixture.database.execute("UPDATE operation_receipts SET detail=? WHERE id=?",
                [SqlParameter.Text(receipt.required(1)), SqlParameter.Text(receipt.required(0))])
            @Expect(validateLifecycleStartupReceipt(fixture.database, context, prepared, grant, encoded).isOk())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }
}
