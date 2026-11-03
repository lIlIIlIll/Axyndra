package agent_host_runtime

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import agent_plugin_registry.{PluginRegistry, ProductPluginRecord, PluginRegistryResult}
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113}
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private class GatewayAudit159e <: AuditPort & CatalogAuditEventDataPort204 {
    private let database: SqliteDatabase
    init(database: SqliteDatabase) { this.database = database }
    public func appendCatalogAuditOwnedUtf8204(value: PreparedPlanUtf8Owner204): Result<Unit> {
        hostAppendCatalogAuditSql204(database, value, "gateway-thread159e", "gateway159e", 14)
    }
    public func append(event: AgentEvent): Result<Unit> {
        try {
            database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "VALUES(?, ?, NULL, 'gateway159e', ?, 14)",
                [SqlParameter.Text("gateway-thread159e"), SqlParameter.Text(event.runId.value),
                    SqlParameter.Text(encodeStoredValue(eventProtocolDetail(event)))])
            Result.Ok(())
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.Internal,
            "fixture.gateway_audit", "actual gateway SQLite audit failed")) }
    }
}
private class GatewayExecutor159e <: ToolExecutor {
    var calls: Int64 = 0
    var saved: ?ToolInvocationContext = None<ToolInvocationContext>
    var retained: ?ToolInvocationContext = None<ToolInvocationContext>
    var retainNext = false
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls++
        @Expect(context.hasOwnedToolSetSnapshot159())
        @Expect(context.permitsToolSnapshotThread159(ThreadId("gateway-thread159e")))
        saved = Some(context)
        if (retainNext) { retained = Some(context.retainInvocationContext159()) }
        Result.Ok(ToolResult(prepared.call.callId, textValue("actual canonical gateway 雪")))
    }
    func checkRevoked159e(): Unit {
        var revoked = false
        try { let _ = saved.getOrThrow().hasToolSetSnapshot159() }
        catch (_: IllegalStateException) { revoked = true }
        @Expect(revoked)
        saved = None<ToolInvocationContext>
    }
    func detachRetained159e(): ToolInvocationContext {
        let value = retained.getOrThrow()
        @Expect(value.hasOwnedToolSetSnapshot159())
        @Expect(value.permitsToolSnapshotThread159(ThreadId("gateway-thread159e")))
        retained = None<ToolInvocationContext>
        value
    }
}
private func gatewayInstall159e(record: ProductPluginRecord, catalog: ToolCatalog,
    executor: GatewayExecutor159e): Unit {
    let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual gateway mount refused") }
    let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
    identity.beginCatalogConstruction159()
    let declared = JavaScriptToolDescriptor("inspect", description: "gateway description 雪",
        inputSchemaJson: "{\"type\":\"object\",\"properties\":{}}")
    identity.reserveTool159(declared, "gateway159e")
    let descriptor = ToolDescriptor(ModelToolDefinition("plugin.pi:gateway159e.inspect", declared.description,
        decodeAgentValue(declared.inputSchemaJson).value().getOrThrow()),
        Capability(CapabilityKind.ExtensionInvoke, resource: "pi:gateway159e"),
        implementationVersion: "gateway159e", implementationFingerprint: "gateway159e:frozen")
    @Expect(catalog.registerBatch([ToolCatalogRegistration(descriptor, executor)], dataPayment: Some(identity)).isOk())
    identity.returnedCatalogConstruction159(); mount.returnedMountFrame159()
}
private func gatewayInvocation159e(gateway: HostCanonicalToolGateway, owner: ?HostDirectPreparationOwner,
    caps: CapabilitySet, suffix: String): Unit {
    let result = gateway.execute(SessionId("gateway-thread159e"), caps,
        ToolCall("gateway-call-" + suffix, "plugin.pi:gateway159e.inspect", objectValue([])),
        InvocationContextProjection(), Some(RunId("gateway-run-" + suffix)), None<ApprovalDecision>,
        directPreparationOwner: owner)
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            @Expect(!value.isError); @Expect(value.receiptId != "")
        case _ => throw IllegalStateException("actual canonical gateway did not complete") }
}
private func gatewayCanonicalConsumerFrame159e(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, directory: String, explicitOwner: Bool): Unit {
    let catalog = ToolCatalog(); let executor = GatewayExecutor159e()
    gatewayInstall159e(record, catalog, executor)
    let database = SqliteDatabase(directory + "/gateway.db")
    try {
        let ids = HostIds(); let operations = DurableOperationStore(database)
        let pipeline = ToolPipeline(catalog, operations, GatewayAudit159e(database), ids)
        let threads = SqliteThreadRuntimeRegistry(database,
            ContextProjector("gateway159e", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let gateway = HostCanonicalToolGateway(database, catalog, pipeline, ids, threads, operations,
            directory, { path => ToolContextDescriptor(workspaceRoot: path, cwd: path) },
            { _ => false }, { _ => Result<Unit>.Ok(()) })
        let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:gateway159e")])
        let initial = probe.retainedCustodyUsage113()
        if (explicitOwner) {
            let owner = HostDirectPreparationOwner({ => Result<Unit>.Ok(()) })
            gatewayInvocation159e(gateway, Some(owner), caps, "owner")
            executor.checkRevoked159e()
            // SQL completion alone cannot return the owner's captured Run.
            @Expect(probe.retainedCustodyUsage113()[0] > initial[0])
            @Expect(owner.closeAcknowledgement().isOk())
            @Expect(probe.retainedCustodyUsage113()[0], initial[0])
            @Expect(probe.retainedCustodyUsage113()[2], initial[2])
        } else {
            executor.retainNext = true
            gatewayInvocation159e(gateway, None<HostDirectPreparationOwner>, caps, "retained")
            executor.checkRevoked159e()
            @Expect(probe.retainedCustodyUsage113()[0] > initial[0])
            let returned = executor.detachRetained159e()
            returned.returnOwnedToolSetFrame159()
            @Expect(probe.retainedCustodyUsage113()[0], initial[0])
            @Expect(probe.retainedCustodyUsage113()[2], initial[2])
            executor.retainNext = false
        }
        gatewayInvocation159e(gateway, None<HostDirectPreparationOwner>, caps, "second")
        executor.checkRevoked159e()
        @Expect(executor.calls, 2)
        @Expect(probe.retainedCustodyUsage113()[0], initial[0])
        @Expect(probe.retainedCustodyUsage113()[2], initial[2])
        @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 2)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
    } finally { database.close() }
    @Expect(catalog.retireCatalogData159())
}
private func gatewayActualRegistry159e(explicitOwner: Bool): Unit {
    let directory = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(directory + "/settings", directory)
    try {
        Directory.create(directory + "/source/extensions", recursive: true)
        File.writeTo(directory + "/source/package.json",
            "{\"name\":\"gateway159e\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(directory + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(directory + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("actual gateway registry import failed") } finally { error.close() } }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    gatewayCanonicalConsumerFrame159e(record, probe, directory, explicitOwner)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(directory, recursive: true) } }
}
@Test
class ActualOwnedDirectGateway159eTests {
    @TestCase
    func actualSqliteGatewayRevokesOrdinaryViewButRetainedConsumerKeepsOriginalBank159e(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { gatewayActualRegistry159e(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualDirectOwnerRetiresOnlyAfterOriginalSqliteCleanupAcknowledgement159e(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { gatewayActualRegistry159e(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
