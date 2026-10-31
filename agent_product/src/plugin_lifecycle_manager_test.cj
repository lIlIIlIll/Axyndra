package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LifecycleManagerFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let config: ProductPluginLifecycleConfiguration
    let processes: LocalProcessPort
    let manager: ProductPluginLifecycleManager
    let database: SqliteDatabase
    let name: String
    let completeCapabilities: Bool
    init(approval!: ApprovalMode = ApprovalMode.Yolo, twoServices!: Bool = false,
        completeCapabilities!: Bool = false, blockedStdin!: Bool = false, maxInputBytes!: Int64 = 8192,
        network!: NetworkPolicy = NetworkPolicy(NetworkPolicyMode.Denied)) {
        this.completeCapabilities = completeCapabilities
        var openedProduct: ?ProductRuntime = None
        var openedPort: ?LocalProcessPort = None
        var openedManager: ?ProductPluginLifecycleManager = None
        var openedDatabase: ?SqliteDatabase = None
        try {
        product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
            settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
            approvalMode: approval, asyncEnabled: false)))
        openedProduct = Some(product)
        let binary = canonicalize(Path(getVariable("AXYNDRA_NATIVE_SERVICE_PLUGIN_FIXTURE").getOrThrow()))
        let source = files.root + "/service-source"
        Directory.create(source)
        pluginCopySnapshotTreeSecure(binary.parent.toString(), source)
        File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
            ValueField("id", textValue("manager-service-fixture")), ValueField("version", textValue("1.0.0")),
            ValueField("entrypoint", textValue(binary.fileName)), ValueField("entry_kind", textValue("native-executable")),
            ValueField("capabilities", listValue([textValue("process.channel")])),
            ValueField("sdk_range", textValue("[2.0.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
            ValueField("contributions", listValue([objectValue([
                ValueField("kind", textValue("service")), ValueField("name", textValue("session"))])]))
        ])).toArray())
        record = match (product.importLocalPlugin(source)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
            case PluginRegistryResult.Ok(_) => ()
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        let service = files.service()
        service.put("network", networkPolicyCanonicalValue(network))
        service.put("executable", textValue("/usr/bin/cat")); service.put("arguments", listValue([]))
        if (blockedStdin) {
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue("-c"), textValue(
                "import os,fcntl,time\nfcntl.fcntl(0,fcntl.F_SETPIPE_SZ,4096)\n" +
                "data=b\"\"\nwhile len(data)<6: data+=os.read(0,6-len(data))\n" +
                "os.write(1,data)\nos.write(2,b\"stdin-held\\n\")\ntime.sleep(25)\n")]))
        }
        service.put("max_input_bytes", integerValue(maxInputBytes))
        service.field("startup").getOrThrow().put("max_input_bytes", integerValue(min(maxInputBytes, 4096)))
        service.put("lifetime_ms", integerValue(30000))
        service.field("startup").getOrThrow().put("timeout_ms", integerValue(10000))
        let document = files.document(service: Some(service))
        let plugin = document.field("plugins").getOrThrow().items[0]
        plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
        plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
        if (twoServices) {
            let secondService = parseUnifiedJson(stringifyUnifiedJson(service))
            secondService.put("id", textValue("secondary"))
            plugin.put("services", listValue([service, secondService]))
        }
        files.write(document)
        config = lifecycleTestRequire(loadPluginLifecycleConfiguration(files.settings,
            productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))))
        processes = LocalProcessPort(LocalWorkspace(files.workspace), sandboxEnabled: true)
        openedPort = Some(processes)
        manager = lifecycleTestRequire(product.vnext.createPluginLifecycleManager(processes))
        openedManager = Some(manager)
        database = SqliteDatabase(files.root + "/state/state.db")
        openedDatabase = Some(database)
        name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio.echo"
        } catch (error: Exception) {
            try { match (openedManager) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedPort) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            files.close()
            throw error
        }
    }
    func ceiling(): CapabilitySet { if (completeCapabilities) { return productCapabilities() }; CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)]) }
    func context(thread: String): ToolInvocationContext {
        // This supplies only host scope. Startup authority is minted by the
        // real maintenance Run, and tool invocations get their own true Run.
        ToolInvocationContext(RunId("scope-only"), SessionId(thread), ceiling(), epoch: 1,
            toolContext: productToolContext(files.workspace))
    }
    func start(thread: String, maintenance: String, decision!: ApprovalDecision = ApprovalDecision.Approve,
        serviceId!: String = "stdio", emptyDirectory!: Bool = false): Result<ProductPluginManagedStart> {
        manager.start(product.vnext, context(thread), ThreadId(maintenance), config, serviceId, "session",
            product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))),
            { endpoint, lease, context, prepared =>
                let _ = lifecycleControlEcho(lease, "real-manager-startup\n")
                let response = product.vnext.javascriptPlugins.prepareService(endpoint,
                    if (emptyDirectory) { "{\"mode\":\"empty_directory\"}" } else { "{\"mode\":\"directory\"}" },
                    JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                        epoch: context.epoch, operationId: "", callId: prepared.call.callId + "-directory", kind: "service_prepare"), context)
                match (response) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(value) => if (value.isError) { lifecycleLeaseError("fixture.discovery_failed") } else { Result.Ok(value.value) }
                }
            }, decision)
    }
    func startProtocol(thread: String, maintenance: String,
        decision!: ApprovalDecision = ApprovalDecision.Approve): Result<ProductPluginManagedStart> {
        manager.startProtocol(product.vnext, context(thread), ThreadId(maintenance), config, "stdio", "session",
            product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))), decision)
    }
    func call(thread: String, callId: String, input!: AgentValue = objectValue([]), restricted!: Bool = false): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread),
            if (restricted) { CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]) } else { ceiling() },
            ToolCall(callId, name, input))
    }
    func visible(thread: ?ThreadId): Bool {
        for (definition in product.tools(threadId: thread) where definition.name == name) { return true }
        false
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        var finished = false
        while (!finished && MonoTime.now() < deadline) {
            finished = manager.close().isOk()
            if (!finished) { sleep(Duration.millisecond * 10) }
        }
        let closed = processes.close()
        let _ = product.close(); database.close()
        if (!finished || closed.isError()) { throw IllegalStateException("manager fixture still owns cleanup") }
        files.close()
    }
}

func managedCompleted(result: Result<ToolInvocationResult>): ToolResult {
    match (lifecycleTestRequire(result)) {
        case ToolInvocationResult.Completed(value) => value
        case _ => throw IllegalStateException("expected canonical managed tool result")
    }
}
func managedRejected(result: Result<ToolInvocationResult>): Bool {
    match (result) {
        case Result.Err(_) => true
        case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
        case Result.Ok(ToolInvocationResult.Denied(_)) => true
        case _ => false
    }
}
class ManagedConflictExecutor <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        throw IllegalStateException("conflict sentinel must never execute")
    }
}

@Test
class ProductPluginLifecycleManagerTests {
    @TestCase
    func realServiceWithEmptyDirectoryRemainsActiveAndRevocableWithoutFakeTool(): Unit {
        let fixture = LifecycleManagerFixture()
        try {
            let service = lifecycleTestRequire(fixture.start("empty-target", "empty-maintenance",
                emptyDirectory: true)).service.getOrThrow()
            @Expect(service.active())
            @Expect(!fixture.visible(Some(ThreadId("empty-target"))))
            @Expect(service.bindingFor(fixture.name).isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.manager.retainedCount(), 1)
            let _ = service.revoke()
            @Expect(!service.active())
            let deadline = MonoTime.now() + Duration.second * 6
            while (fixture.manager.retainedCount() != 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.manager.retainedCount(), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func sameThreadConfiguredServicesWithEqualLocalToolNamesRemainIndependent(): Unit {
        let fixture = LifecycleManagerFixture(twoServices: true)
        try {
            let first = lifecycleTestRequire(fixture.start("two-services-target", "first-service-maintenance")).service.getOrThrow()
            let second = lifecycleTestRequire(fixture.start("two-services-target", "second-service-maintenance",
                serviceId: "secondary")).service.getOrThrow()
            let secondName = fixture.name.replace(".stdio.", ".secondary.")
            @Expect(managedCompleted(fixture.call("two-services-target", "first-service-call")).output
                .field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "1")
            let secondCall = fixture.product.vnext.executeCanonicalTool(SessionId("two-services-target"), fixture.ceiling(),
                ToolCall("second-service-call", secondName, objectValue([])))
            @Expect(managedCompleted(secondCall).output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "1")
            let _ = first.revoke()
            @Expect(!fixture.visible(Some(ThreadId("two-services-target"))))
            @Expect(second.active())
            let survivingCall = fixture.product.vnext.executeCanonicalTool(SessionId("two-services-target"), fixture.ceiling(),
                ToolCall("surviving-service-call", secondName, objectValue([])))
            @Expect(managedCompleted(survivingCall).output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "2")
        } finally { fixture.close() }
    }

    @TestCase
    func realStartupPublishesThreadScopedToolsWithExactEndpointLeaseIdentityAndRevokesOnDisable(): Unit {
        let fixture = LifecycleManagerFixture()
        try {
            @Expect(!fixture.visible(Some(ThreadId("manager-target"))))
            let started = lifecycleTestRequire(fixture.start("manager-target", "manager-maintenance"))
            let service = started.service.getOrThrow()
            @Expect(service.active())
            @Expect(fixture.visible(Some(ThreadId("manager-target"))))
            @Expect(!fixture.visible(None) && !fixture.visible(Some(ThreadId("other-thread"))))
            let binding = lifecycleTestRequire(service.bindingFor(fixture.name))
            @Expect(lifecycleText(binding, "implementation_fingerprint").startsWith("owned-v1:"))
            @Expect(lifecycleText(binding, "endpoint_identity") != lifecycleText(binding, "instance_identity"))
            @Expect(lifecycleText(binding, "lease_id") != "")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='running'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let first = managedCompleted(fixture.call("manager-target", "managed-first"))
            @Expect(!first.isError)
            @Expect(first.output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "1")
            @Expect(managedRejected(fixture.call("manager-target", "managed-low-scope", restricted: true)))
            @Expect(managedRejected(fixture.call("other-thread", "managed-wrong-thread")))
            let second = managedCompleted(fixture.call("manager-target", "managed-second"))
            @Expect(second.output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "2")
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(!fixture.visible(Some(ThreadId("manager-target"))))
            @Expect(!service.active())
            @Expect(managedRejected(fixture.call("manager-target", "managed-after-disable")))
            let deadline = MonoTime.now() + Duration.second * 6
            while (fixture.manager.retainedCount() != 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.manager.retainedCount(), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func sameMountDifferentThreadsPublishDistinctExecutorsAndCatalogConflictHasNoPartialDirectory(): Unit {
        let fixture = LifecycleManagerFixture()
        try {
            let first = lifecycleTestRequire(fixture.start("target-one", "maintenance-one")).service.getOrThrow()
            let second = lifecycleTestRequire(fixture.start("target-two", "maintenance-two")).service.getOrThrow()
            let one = lifecycleTestRequire(first.bindingFor(fixture.name))
            let two = lifecycleTestRequire(second.bindingFor(fixture.name))
            @Expect(lifecycleText(one, "instance_identity"), lifecycleText(two, "instance_identity"))
            @Expect(lifecycleText(one, "endpoint_identity") != lifecycleText(two, "endpoint_identity"))
            @Expect(lifecycleText(one, "implementation_fingerprint") != lifecycleText(two, "implementation_fingerprint"))
            @Expect(managedCompleted(fixture.call("target-one", "one-call")).output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "1")
            @Expect(managedCompleted(fixture.call("target-two", "two-call")).output.field("result").getOrThrow().field("calls").getOrThrow().asNumberText(), "1")
        } finally { fixture.close() }
        let conflicting = LifecycleManagerFixture()
        try {
            let status = conflicting.name.replace(".echo", ".status")
            lifecycleTestRequire(conflicting.product.registerTool(ToolDescriptor(ModelToolDefinition(status,
                "conflicting host entry", objectValue([ValueField("type", textValue("object"))])),
                Capability(CapabilityKind.ExtensionInvoke), sideEffecting: false), ManagedConflictExecutor()))
            @Expect(conflicting.start("conflict-target", "conflict-maintenance").isError())
            @Expect(!conflicting.visible(Some(ThreadId("conflict-target"))))
            // Startup really completed, but no member of the two-tool batch
            // became visible when its second name conflicted with the host.
            @Expect(conflicting.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            let deadline = MonoTime.now() + Duration.second * 6
            while (conflicting.manager.retainedCount() != 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
            @Expect(conflicting.manager.retainedCount(), 0)
        } finally { conflicting.close() }
    }

    @TestCase
    func actualActiveIoRequestIsTypedDeniedWithoutCreatingChildOrWashingSuccess(): Unit {
        let fixture = LifecycleManagerFixture()
        try {
            let _ = lifecycleTestRequire(fixture.start("no-active-io", "no-active-io-maintenance"))
            let result = fixture.call("no-active-io", "active-io-probe",
                input: objectValue([ValueField("mode", textValue("active_io_probe"))]))
            @Expect(managedRejected(result))
            let code = match (result) {
                case Result.Err(error) => error.code
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.output.field("error").getOrThrow().text
                case _ => "unexpected"
            }
            @Expect(code, "channel.service_unsupported")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func rejectedRealApprovalCannotRunStartupOrPublishDirectory(): Unit {
        let fixture = LifecycleManagerFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let result = fixture.start("rejected-target", "rejected-maintenance", decision: ApprovalDecision.Reject)
            @Expect(match (result) { case Result.Err(_) => true; case Result.Ok(value) => value.service.isNone() })
            @Expect(!fixture.visible(Some(ThreadId("rejected-target"))))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
        } finally { fixture.close() }
    }
}
