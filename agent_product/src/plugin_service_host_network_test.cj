package agent_product

import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_store.*
import tool_runtime.*
import process4cj as host_network_process
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func hostNetworkPeerSource(): String {
    Path(getVariable("AXYNDRA_MCP_TEST_SERVER").getOrThrow()).parent.join("host_network.py").toString()
}
class HostNetworkOrigin {
    let root: String
    let process: host_network_process.ManagedProcess
    let port: Int64
    init() {
        let directory = Directory.createTemp("/tmp").toString()
        root = directory
        let started = host_network_process.startProcess(host_network_process.ProcessCommand("/usr/bin/python3",
            arguments: ["-u", hostNetworkPeerSource(), "origin", directory],
            terminateProcessTree: true, maxOutputBytes: 65536))
        process = started
        try {
            rawChannelAwaitFile(directory + "/port")
            port = Int64.parse(String.fromUtf8(File.readFrom(directory + "/port")))
        } catch (error: Exception) {
            let _ = started.terminate(force: true); let _ = started.close()
            remove(directory, recursive: true); throw error
        }
    }
    func connections(): Int64 {
        let text = String.fromUtf8(File.readFrom(root + "/connections"))
        if (text == "") { return -1 } // A transient write is never success evidence.
        Int64.parse(text)
    }
    func awaitConnections(expected: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 3
        while (connections() != expected && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (connections() != expected) { throw IllegalStateException("actual listener count differs") }
    }
    func close(): Unit {
        try { let _ = process.terminate(force: true); let _ = process.close() }
        finally { remove(root, recursive: true) }
    }
}

// Uses the real separately packaged MCP endpoint, Product public startup,
// actual Python backend in bwrap, localhost listener, SQLite, and receipts.
class HostNetworkProductFixture {
    let base: McpProductFixture
    let origin: HostNetworkOrigin
    init(host!: Bool = true, approval!: ApprovalMode = ApprovalMode.Yolo) {
        let listener = HostNetworkOrigin()
        let fixture = try { McpProductFixture(approval: approval) }
            catch (error: Exception) { listener.close(); throw error }
        base = fixture; origin = listener
        try {
            let peer = fixture.files.external + "/host-network-peer.py"
            File.writeTo(peer, File.readFrom(hostNetworkPeerSource()))
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(fixture.files.settings + "/plugins/lifecycle.json")))
            let service = document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
            service.put("network", networkPolicyCanonicalValue(NetworkPolicy(
                if (host) { NetworkPolicyMode.HostNetwork } else { NetworkPolicyMode.Denied })))
            service.put("arguments", listValue([textValue("-u"), textValue(peer), textValue("peer"),
                textValue(fixture.transcript), textValue(listener.port.toString())]))
            fixture.files.write(document)
        } catch (error: Exception) {
            try { fixture.close() } finally { listener.close() }
            throw error
        }
    }
    func reply(thread: String, call: String): AgentValue {
        let result = managedCompleted(base.call(thread, call))
        if (result.isError) { throw IllegalStateException("actual backend probe failed") }
        parseUnifiedJson(result.output.field("result").getOrThrow().field("content").getOrThrow().items[0]
            .field("text").getOrThrow().text)
    }
    func close(): Unit { try { base.close() } finally { origin.close() } }
}
func hostNetworkWithoutNetwork(): CapabilitySet {
    let values = ArrayList<Capability>()
    for (value in productCapabilities().values where value.kind != CapabilityKind.NetworkAccess) { values.add(value) }
    CapabilitySet(values: values.toArray())
}

@Test
class PluginServiceHostNetworkTests {
    @TestCase
    func actualApprovedBackendHostConnectsWhileDeniedBackendCannot(): Unit {
        let previous = getVariable("AXYNDRA_HOST_NETWORK_UNGRANTED")
        setVariable("AXYNDRA_HOST_NETWORK_UNGRANTED", "must-not-reach-service")
        try {
            for (host in [false, true]) {
                let fixture = HostNetworkProductFixture(host: host)
                try {
                    let thread = if (host) { "host-backend" } else { "denied-backend" }
                    @Expect(!managedCompleted(fixture.base.start(thread)).isError)
                    let output = fixture.reply(thread, "actual-network-call")
                    @Expect(output.field("connected").getOrThrow().asBool(), host)
                    @Expect(output.field("ambient_absent").getOrThrow().asBool())
                    if (host) {
                        @Expect(fixture.base.product.sandboxCaBundle != "")
                        @Expect(output.field("fixed_ca").getOrThrow().asBool())
                    }
                    fixture.origin.awaitConnections(if (host) { 1 } else { 0 })
                    @Expect(fixture.base.calls(), 1)
                    @Expect(fixture.base.childReceipts("completed"), 1)
                    let rows = fixture.base.database.query("SELECT o.normalized_plan FROM operations o " +
                        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                        [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
                    @Expect(rows.size, 1)
                    let binding = decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow()
                        .field("binding").getOrThrow()
                    let policy = lifecycleTestRequire(parseNetworkPolicy(binding.field("network").getOrThrow()))
                    @Expect(networkPolicyModeIsHost(policy.mode), host)
                    let capabilities = CapabilitySet(values: lifecycleTestRequire(channelServiceRequiredCapabilities(binding)))
                    @Expect(capabilities.allows(CapabilityKind.NetworkAccess, resource: "[\"host\"]"), host)
                } finally { fixture.close() }
            }
        } finally {
            match (previous) { case Some(value) => setVariable("AXYNDRA_HOST_NETWORK_UNGRANTED", value)
                case None => removeVariable("AXYNDRA_HOST_NETWORK_UNGRANTED") }
        }
    }

    @TestCase
    func explicitStartupRejectionHasNoProcessHandoffOrRemoteFrames(): Unit {
        let fixture = HostNetworkProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(managedRejected(fixture.base.start("rejected-host", decision: ApprovalDecision.Reject)))
            @Expect(fixture.base.observed().size, 0)
            @Expect(fixture.base.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(!fixture.base.visible("rejected-host"))
            fixture.origin.awaitConnections(0)
        } finally { fixture.close() }
    }

    @TestCase
    func missingHostCapabilityRejectsActualStartupBeforeEffect(): Unit {
        // This actual manager grants only ProcessSpawn+ExtensionInvoke. The
        // fixed operator Host grant is not a substitute for NetworkAccess.
        let fixture = LifecycleManagerFixture(network: NetworkPolicy(NetworkPolicyMode.HostNetwork))
        try {
            let result = fixture.startProtocol("no-network-ceiling", "no-network-maintenance")
            @Expect(result.isError() || managedRejected(Result.Ok(result.value().getOrThrow().outcome)))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(!fixture.visible(Some(ThreadId("no-network-ceiling"))))
            // Even an unlaunched manager placeholder retires by asynchronous
            // cleanup ACK; use the existing manager fixture's finite bound.
            let cleanupDeadline = MonoTime.now() + Duration.second * 8
            while (fixture.manager.retainedCount() != 0 && MonoTime.now() < cleanupDeadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.manager.retainedCount(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(!fixture.visible(Some(ThreadId("no-network-ceiling"))))
        } finally { fixture.close() }
    }

    @TestCase
    func lowerAuthorityAndAnotherThreadCannotReuseHostBackendThenConfigRevokesIt(): Unit {
        let fixture = HostNetworkProductFixture()
        try {
            @Expect(!managedCompleted(fixture.base.start("host-owner")).isError)
            @Expect(fixture.reply("host-owner", "first").field("connected").getOrThrow().asBool())
            @Expect(managedRejected(fixture.base.call("host-owner", "low-authority", capabilities: hostNetworkWithoutNetwork())))
            @Expect(managedRejected(fixture.base.call("another-thread", "same-tool")))
            @Expect(fixture.base.calls(), 1)
            @Expect(fixture.base.childReceipts("completed"), 1)
            let path = fixture.base.files.settings + "/plugins/lifecycle.json"
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
                .put("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied)))
            fixture.base.files.write(document)
            let deadline = MonoTime.now() + Duration.second * 8
            while (fixture.base.retained() != 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.base.retained(), 0)
            @Expect(!fixture.base.visible("host-owner"))
            @Expect(managedRejected(fixture.base.call("host-owner", "old-registration")))
            @Expect(fixture.base.calls(), 1)
            fixture.origin.awaitConnections(1)
        } finally { fixture.close() }
    }

    @TestCase
    func hostBackendGrantDoesNotGivePinnedEndpointAmbientNetwork(): Unit {
        let origin = HostNetworkOrigin()
        let fixture = try { LifecycleManagerFixture(completeCapabilities: true,
            network: NetworkPolicy(NetworkPolicyMode.HostNetwork)) }
            catch (error: Exception) { origin.close(); throw error }
        try {
            let result = lifecycleTestRequire(fixture.manager.start(fixture.product.vnext, fixture.context("isolated-endpoint"),
                ThreadId("endpoint-maintenance"), fixture.config, "stdio", "session",
                fixture.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))),
                { endpoint, lease, context, prepared =>
                    let _ = lifecycleControlEcho(lease, "actual-host-backend\n")
                    let reply = match (fixture.product.vnext.javascriptPlugins.prepareService(endpoint,
                        stringifyUnifiedJson(objectValue([ValueField("mode", textValue("endpoint_network_probe")),
                            ValueField("port", integerValue(origin.port))])),
                        JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                            epoch: context.epoch, operationId: "", callId: prepared.call.callId + "-probe", kind: "service_prepare"), context)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
                    }
                    if (reply.isError || reply.value.field("network_connected").isNone() ||
                        reply.value.field("network_connected").getOrThrow().asBool()) {
                        return lifecycleLeaseError("fixture.endpoint_network_not_isolated")
                    }
                    Result.Ok(objectValue([ValueField("tools", listValue([]))]))
                }, ApprovalDecision.Approve))
            @Expect(!managedCompleted(Result.Ok(result.outcome)).isError)
            @Expect(result.service.isSome())
            origin.awaitConnections(0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        } finally { try { fixture.close() } finally { origin.close() } }
    }

    @TestCase
    func rawHostRequestStillDeniedAndCustomPortCannotBypassPrivateGrantLauncher(): Unit {
        let raw = ChannelFactoryFixture("host-still-denied")
        try {
            @Expect(channelFactoryCode(raw.port.openChannel(channelFactoryPython("raw-host-forbidden", "print('bad')",
                network: NetworkPolicy(NetworkPolicyMode.HostNetwork)), raw.source.token)), "process.channel_policy_denied")
            @Expect(!raw.port.hasActiveOperation(OperationId("raw-host-forbidden")))
        } finally { raw.close() }
        let files = LifecycleConfigurationFixture()
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
            settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
        let database = SqliteDatabase(files.root + "/state/state.db")
        let port = LifecycleCleanupGate(files.workspace)
        let owner = ProductPluginLifecycleOwner(database, port)
        try {
            let service = files.service(); service.put("executable", textValue("/usr/bin/cat")); service.put("arguments", listValue([]))
            service.put("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.HostNetwork)))
            files.write(files.document(service: Some(service)))
            let config = lifecycleTestRequire(files.load())
            let context = ToolInvocationContext(RunId("scope-only"), SessionId("custom-port-target"), productCapabilities(),
                epoch: 1, toolContext: productToolContext(files.workspace))
            let grant = lifecycleTestRequire(config.bindService("stdio", ThreadId("custom-port-target"), "custom-port-instance",
                files.workspace, ExecutionResourceLimits(), pluginInvocationAuthorityScope(context)))
            let control = ProductPluginLifecycleControl(owner)
            lifecycleTestRequire(product.registerTool(control.descriptor(), control))
            let result = control.launch(product.vnext, SessionId("custom-port-maintenance"), grant, productCapabilities(),
                { _, _, _ => throw IllegalStateException("custom port must not reach startup callback") },
                approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(result.isError())
            if (result.isError()) {
                @Expect(result.error().getOrThrow().code, "plugin.lifecycle_start_unknown")
                @Expect(result.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired)
            }
            @Expect(port.opens, 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            // This generic control operation already crossed handoff, so the
            // existing conservative startup classification remains Unknown.
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
        } finally {
            try { let _ = owner.close(); let _ = port.port.close(); let _ = product.close() }
            finally { database.close(); files.close() }
        }
    }
    @TestCase
    func privateHostLauncherWithoutFixedCaCannotInheritAmbientCa(): Unit {
        // Actual private factory + operator grant + bwrap process. This is a
        // launcher-environment boundary test, not a canonical Store admission.
        let previousSsl = getVariable("SSL_CERT_FILE")
        let previousCurl = getVariable("CURL_CA_BUNDLE")
        let fixture = LifecycleConfigurationFixture()
        let port = LocalProcessPort(LocalWorkspace(fixture.workspace), sandboxEnabled: true, sandboxCaBundle: "")
        let source = CancellationSource()
        let operation = OperationId("host-empty-fixed-ca")
        try {
            setVariable("SSL_CERT_FILE", "ambient-ssl-ca-must-not-enter")
            setVariable("CURL_CA_BUNDLE", "ambient-curl-ca-must-not-enter")
            let service = fixture.service()
            service.put("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.HostNetwork)))
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue("-c"), textValue(
                "import os,json; print(json.dumps({'ssl_absent':'SSL_CERT_FILE' not in os.environ," +
                "'curl_absent':'CURL_CA_BUNDLE' not in os.environ}))")]))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            let request = lifecycleTestRequire(grant.processRequest(operation))
            @Expect(networkPolicyModeIsHost(request.networkPolicy.mode))
            let channel = lifecycleTestRequire(port.openLifecycleChannel(request, grant, source.token, 8192))
            @Expect(channel.closeInput().isOk())
            let output = parseUnifiedJson(String.fromUtf8(rawChannelReadAll(channel, ProcessChannelStream.Stdout)))
            @Expect(output.field("ssl_absent").getOrThrow().asBool())
            @Expect(output.field("curl_absent").getOrThrow().asBool())
            @Expect(rawChannelReadAll(channel, ProcessChannelStream.Stderr).isEmpty())
            channelFactoryAwaitOperationClosed(port, operation)
            @Expect(!port.hasActiveOperation(operation))
        } finally {
            try {
                channelFactoryAwaitOperationClosed(port, operation)
                @Expect(port.close().isOk())
            } finally {
                source.close()
                match (previousSsl) { case Some(value) => setVariable("SSL_CERT_FILE", value); case None => removeVariable("SSL_CERT_FILE") }
                match (previousCurl) { case Some(value) => setVariable("CURL_CA_BUNDLE", value); case None => removeVariable("CURL_CA_BUNDLE") }
                fixture.close()
            }
        }
    }

}
