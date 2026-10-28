package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import process4cj as fixture_process
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Uses Product's sole public manager and the actual packaged native plugin.
// Only the HTTP origin is a fixture; no broker/transport/catalog/Receipt fake.
class McpHttpProductFixture {
    let root: String
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let origin: fixture_process.ManagedProcess
    let endpoint: String
    let url: String
    let secret = "HTTP-MCP-private-credential-72ca"
    let name: String
    init(mode!: String = "echo", sse!: Bool = false, approval!: ApprovalMode = ApprovalMode.Yolo,
        headerPrefix!: String = "", publicHeaders!: Bool = false, readOnlyTools!: Array<String> = [],
        askOnNetwork!: Bool = true, payloadProfile!: Bool = false) {
        root = pluginContractTemp("mcp-http-product")
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        var startedOrigin: ?fixture_process.ManagedProcess = None
        try {
            Directory.create(root + "/origin", recursive: true)
            Directory.create(root + "/workspace", recursive: true)
            File.writeTo(root + "/origin/credential", secret.toArray())
            File.writeTo(root + "/origin/header-prefix", headerPrefix.toArray())
            if (publicHeaders) { File.writeTo(root + "/origin/require-public-headers", "1".toArray()) }
            File.writeTo(root + "/origin/mode", mode.toArray())
            origin = fixture_process.startProcess(fixture_process.ProcessCommand("/usr/bin/python3",
                arguments: [getVariable("AXYNDRA_MCP_HTTP_TEST_SERVER").getOrThrow(), "--root", root + "/origin"],
                workingDirectory: root, terminateProcessTree: true, maxOutputBytes: 65536))
            startedOrigin = Some(origin)
            let deadline = MonoTime.now() + Duration.second * 5
            while (!exists(Path(root + "/origin/ready.json")) && origin.isAlive() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 10)
            }
            if (!exists(Path(root + "/origin/ready.json"))) { throw IllegalStateException("MCP HTTP origin did not become ready") }
            let ready = parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/origin/ready.json")))
            endpoint = "http://127.0.0.1:" + ready.field("port").getOrThrow().asNumberText() + "/mcp"
            url = endpoint + "?a=1&a=%2f&b=@exact&snow=%E9%9B%AA"
            if (!askOnNetwork) {
                Directory.create(root + "/settings", recursive: true)
                File.writeTo(root + "/settings/config.yml",
                    "schema_version: 1\napproval:\n  ask_on_network: false\n".toArray())
            }
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
                approvalMode: approval, asyncEnabled: false)))
            openedProduct = Some(product)
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_MCP_CLIENT_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:mcp-client" ||
                !record.descriptor.hasCapability("network.http")) {
                throw IllegalStateException("fresh dual-transport MCP package is required")
            }
            if (!exists(Path(root + "/settings/credentials"))) { Directory.create(root + "/settings/credentials", recursive: true) }
            File.writeTo(root + "/settings/credentials/mcp-header", secret.toArray())
            if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
            let configuration = objectValue([ValueField("version", integerValue(1)), ValueField("transport", textValue("http")),
                ValueField("request_timeout_ms", integerValue(if (payloadProfile) { 60000 } else { 10000 })), ValueField("directory", objectValue([
                    ValueField("max_pages", integerValue(8)), ValueField("max_tools", integerValue(64))])),
                ValueField("http", objectValue([ValueField("url", textValue(url)),
                    ValueField("credential_refs", listValue([textValue("mcp-token")])),
                    ValueField("max_response_bytes", integerValue(if (payloadProfile) { 8388608 } else { 8192 })), ValueField("prefer_sse", boolValue(sse)),
                    ValueField("origin", textValue(if (publicHeaders) { "https://client.example.test" } else { "" })),
                    ValueField("headers", if (publicHeaders) { objectValue([ValueField("X-Deployment", textValue("operator-public"))]) } else { objectValue([]) })]))])
            let document = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("configuration", configuration), ValueField("requests", listValue([objectValue([
                    ValueField("url", textValue(endpoint)), ValueField("methods", listValue([textValue("POST")])),
                    ValueField("private_addresses", listValue([textValue("127.0.0.1")])),
                    ValueField("credential_refs", listValue([textValue("mcp-token")]))])])),
                ValueField("credentials", listValue([objectValue([ValueField("ref", textValue("mcp-token")),
                    ValueField("source", objectValue([ValueField("file", textValue("mcp-header"))])),
                    ValueField("injection", objectValue([ValueField("header", textValue("Authorization")), ValueField("prefix", textValue(headerPrefix))]))])]))
            ])]))])
            if (payloadProfile) {
                let plugin = document.field("plugins").getOrThrow().items[0]
                plugin.put("protocol_limits", capacityTestProfile())
                plugin.put("payload_limits", payloadProductLimits())
            }
            if (!readOnlyTools.isEmpty()) {
                document.field("plugins").getOrThrow().items[0].put("read_only_tools", listValue(readOnlyTools.map { name => textValue(name) }))
            }
            File.writeTo(root + "/settings/plugins/services.json", stringifyUnifiedJson(document).toArray())
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            database = SqliteDatabase(root + "/state/state.db"); openedDatabase = Some(database)
            name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.session.t_" + modelPolicySha256Text("remote.echo:雪")
        } catch (error: Exception) {
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            try { match (startedOrigin) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            let _ = removeIfExists(root, recursive: true)
            throw error
        }
    }
    func installCompactionPolicy(): Unit {
        let policy = match (product.importLocalPlugin(getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow())) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        try {
            let namespace = productRegistryCopyText83(policy.descriptor.copyText(PluginDescriptorText.Namespace))
            let digest = productRegistryCopyText83(policy.descriptor.copyText(PluginDescriptorText.ContentDigest))
            File.writeTo(root + "/settings/plugins/policies.json", stringifyUnifiedJson(objectValue([
                ValueField("version", integerValue(1)), ValueField("bindings", objectValue([ValueField("compaction", objectValue([
                    ValueField("namespace", textValue(namespace)), ValueField("provider", textValue("summarize")),
                    ValueField("package_digest", textValue(digest))]))]))])).toArray())
            File.writeTo(root + "/settings/plugins/canonical-data.json", encodeAgentValue(objectValue([
                ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                    ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
                    ValueField("tools", listValue([canonicalCheckpointFixtureGrant173("checkpoint"),
                        canonicalCheckpointFixtureGrant173("rewind")]))])]))])).toArray())
            match (product.setPluginEnabled(namespace, true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
        } finally { policy.close() }
    }
    func toolName(remote: String): String { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.session.t_" + modelPolicySha256Text(remote) }
    func command(): String { "/plugins service start " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + " session session" }
    func start(thread: String): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "session", "session",
            approvalDecision: ApprovalDecision.Approve, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func call(thread: String, id: String, name!: String = "", input!: AgentValue = objectValue([]), maxCalls!: Int64 = 2): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), productCapabilities(),
            ToolCall(id, if (name == "") { this.name } else { name }, input),
            budget: ExecutionBudget(maxToolCalls: maxCalls, maxConcurrentTools: 1))
    }
    func refresh(thread: String): Result<ToolInvocationResult> {
        product.refreshPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "session",
            approvalDecision: ApprovalDecision.Approve, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func observed(): Array<AgentValue> {
        parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/origin/observed.json")), maxBytes: 16777216).items.toArray()
    }
    func calls(): Int64 {
        var count: Int64 = 0
        for (row in observed() where lifecycleText(row, "method") == "tools/call") { count += 1 }
        count
    }
    func awaitCalls(count: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (calls() < count && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (calls() != count) { throw IllegalStateException("MCP HTTP origin call count differs") }
    }
    func awaitClosed(index: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (MonoTime.now() < deadline) {
            let rows = observed()
            if (rows.size > index && rows[index].field("closed").getOrThrow().asBool()) { return }
            sleep(Duration.millisecond * 10)
        }
        throw IllegalStateException("MCP HTTP origin did not observe actual socket close")
    }
    func childReceipts(outcome: String): Int64 {
        database.query("SELECT r.id FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id " +
            "WHERE e.tool_id=? AND r.outcome=?", [SqlParameter.Text(HOST_HTTP_STREAM_TOOL), SqlParameter.Text(outcome)]).size
    }
    func childArguments(call: String): AgentValue {
        let rows = database.query("SELECT o.normalized_plan FROM operations o JOIN derived_operation_admissions a ON a.operation_id=o.id " +
            "WHERE a.request_key=?", [SqlParameter.Text("http-stream-service:" + call + ":mcp-call")])
        if (rows.size != 1) { throw IllegalStateException("one actual HTTP child plan is required") }
        decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow()
    }
    func visible(thread: String, selected!: String = ""): Bool {
        let expected = if (selected == "") { name } else { selected }
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == expected) { return true }
        false
    }
    func status(thread: String): AgentValue {
        for (value in product.pluginServiceStatuses() where lifecycleText(value, "target_thread_id") == thread) { return value }
        throw IllegalStateException("expected retained HTTP service status")
    }
    func waitReleased(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (MonoTime.now() < deadline) {
            var retained = false
            for (status in product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()) { retained = true }
            if (!retained) { return }
            sleep(Duration.millisecond * 10)
        }
        throw IllegalStateException("HTTP service cleanup ownership remains")
    }
    func assertNoSecrets(output!: AgentValue = objectValue([])): Unit {
        @Expect(!pluginHttpTestValueContainsSecret(output, [secret]))
        for (query in ["SELECT normalized_plan FROM operations", "SELECT normalized_plan FROM operation_effect_records",
            "SELECT detail FROM operation_receipts", "SELECT verification FROM operation_receipts", "SELECT payload FROM items",
            "SELECT payload FROM audit_events"]) {
            for (row in database.query(query)) {
                let text = row.required(0)
                @Expect(!text.contains(secret))
                @Expect(!text.contains(productBase64Bytes(secret.toArray())))
                @Expect(!text.contains(pluginHttpPercentEncode(secret)))
                let decoded = try { decodeStoredValue(text) } catch (_: Exception) {
                    parseUnifiedJson(text, maxBytes: 1048576, maxDepth: 64)
                }
                @Expect(!pluginHttpTestValueContainsSecret(decoded, [secret]))
            }
        }
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        var closed = false
        try {
            while (!closed && MonoTime.now() < deadline) {
                closed = product.close().isOk()
                if (!closed) { sleep(Duration.millisecond * 20) }
            }
            if (!closed) { throw IllegalStateException("HTTP Product cleanup has no acknowledgement") }
        } finally {
            try { database.close() } finally { try { let _ = origin.close() } finally { remove(root, recursive: true) } }
        }
    }
}

@Test
class PluginMcpHttpServiceTests {
    @TestCase
    func explicitBearerPrefixAndPublicHeadersReachRealOriginWithoutEnteringSecretAudit(): Unit {
        let fixture = McpHttpProductFixture(headerPrefix: "Bearer ", publicHeaders: true)
        try {
            @Expect(!managedCompleted(fixture.start("http-auth")).isError)
            let result = managedCompleted(fixture.call("http-auth", "auth-call"))
            @Expect(!result.isError)
            @Expect(fixture.calls(), 1)
            for (row in fixture.observed()) {
                @Expect(row.field("authorized").getOrThrow().asBool())
                @Expect(lifecycleText(row, "origin"), "https://client.example.test")
                @Expect(lifecycleText(row, "deployment"), "operator-public")
            }
            let args = fixture.childArguments("auth-call")
            let request = args.field("intent").getOrThrow().field("request").getOrThrow()
            @Expect(lifecycleText(request.field("headers").getOrThrow(), "Origin"), "https://client.example.test")
            @Expect(lifecycleText(request.field("headers").getOrThrow(), "X-Deployment"), "operator-public")
            @Expect(!stringifyUnifiedJson(request.field("headers").getOrThrow()).toAsciiLower().contains("authorization"))
            @Expect(fixture.childReceipts("completed"), 1)
            fixture.assertNoSecrets(output: result.output)
        } finally { fixture.close() }
    }

    @TestCase
    func bareAndPrefixedCredentialReflectionRemainUnknownAndCannotRetry(): Unit {
        for (mode in ["reflect", "reflect-prefixed"]) {
            let fixture = McpHttpProductFixture(mode: mode, headerPrefix: "Bearer ", publicHeaders: true)
            try {
                @Expect(!managedCompleted(fixture.start("http-auth-reflect")).isError)
                let result = fixture.call("http-auth-reflect", "auth-reflect")
                @Expect(result.isError())
                @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
                @Expect(fixture.calls(), 1)
                @Expect(fixture.childReceipts("unknown"), 1)
                @Expect(managedRejected(fixture.call("http-auth-reflect", "no-retry")))
                @Expect(fixture.calls(), 1)
                fixture.waitReleased()
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func persistentApplicationNeedsApprovalBeforeThreeRealDiscoveryExchanges(): Unit {
        let fixture = McpHttpProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-mcp-app")))
            let denied = session.handle(fixture.command())
            @Expect(denied.isError())
            @Expect(denied.error().getOrThrow().code, "plugin.service_approval_required")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(session.approval().isNone())
            let started = lifecycleTestRequire(session.handle(fixture.command() + " --approve"))
            @Expect(!started.agentInvoked && started.approval.isNone())
            let observed = fixture.observed()
            @Expect(observed.size, 3)
            @Expect(lifecycleText(observed[0], "method"), "server/discover")
            @Expect(lifecycleText(observed[1], "method"), "tools/list")
            @Expect(lifecycleText(observed[2], "method"), "tools/list")
            var responseBytes: Int64 = 0
            for (row in observed) {
                @Expect(row.field("authorized").getOrThrow().asBool())
                @Expect(lifecycleText(row, "path"), "/mcp?a=1&a=%2f&b=@exact&snow=%E9%9B%AA")
                let count = lifecycleInt(row, "response_bytes", 8192)
                responseBytes += count
            }
            @Expect(responseBytes > 8192)
            @Expect(fixture.visible("http-mcp-app") && !fixture.visible("foreign-thread"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            let startup = fixture.database.query("SELECT r.thread_id,i.provenance FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN items i ON i.id=o.tool_call_item_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                [SqlParameter.Text(PLUGIN_HTTP_LIFECYCLE_TOOL)])
            @Expect(startup.size, 1)
            @Expect(startup[0].required(0) != session.id().value)
            match (effectiveDirectCallOrigin(decodeStoredProvenance(startup[0].required(1)))) {
                case DirectCallOrigin.HostService(origin) => @Expect(origin.action, HostServiceAction.Start)
                case _ => @Expect(false)
            }
            @Expect(fixture.childReceipts("completed"), 0)
            fixture.assertNoSecrets()
            let quit = session.handle("/quit")
            if (quit.isError()) { @Expect(quit.error().getOrThrow().code, "plugin.lifecycle_manager_cleanup_pending") }
            closeApplicationServices(session)
            @Expect(lifecycleTestRequire(session.handle("/quit")).exitRequested)
            fixture.waitReleased()
            @Expect(!fixture.visible("http-mcp-app"))
        } finally { fixture.close() }
    }

    @TestCase
    func directCallUsesOwnedExactHttpIntentSingleSlotAndEarlySseReceipt(): Unit {
        let fixture = McpHttpProductFixture(sse: true)
        try {
            @Expect(!managedCompleted(fixture.start("http-mcp-direct")).isError)
            let input = objectValue([ValueField("query", textValue("雪 &=+?#/%\n\\\""))])
            let result = managedCompleted(fixture.call("http-mcp-direct", "http-direct", input: input))
            @Expect(!result.isError)
            @Expect(lifecycleText(result.output, "status"), "complete")
            fixture.awaitCalls(1); fixture.awaitClosed(3)
            let args = fixture.childArguments("http-direct")
            let request = args.field("intent").getOrThrow().field("request").getOrThrow()
            @Expect(lifecycleText(request, "body_hex"), lifecycleText(fixture.observed()[3], "body_hex"))
            @Expect(lifecycleText(request, "url"), fixture.url)
            @Expect(request.field("credential_refs").getOrThrow().items[0].text, "mcp-token")
            @Expect(!stringifyUnifiedJson(request.field("headers").getOrThrow()).toAsciiLower().contains("authorization"))
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            let rows = fixture.database.query("SELECT r.id,r.detail FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id " +
                "WHERE e.tool_id=?", [SqlParameter.Text(HOST_HTTP_STREAM_TOOL)])
            @Expect(rows.size, 1)
            @Expect(rows[0].required(0) != "")
            let closed = decodeStoredValue(rows[0].required(1)).field("output").getOrThrow()
            @Expect(closed.field("closed").getOrThrow().asBool())
            @Expect(!closed.field("body_eof").getOrThrow().asBool())
            @Expect(lifecycleInt(closed, "consumed_bytes", 8192) > 0)
            @Expect(!fixture.observed()[3].field("eof_sent").getOrThrow().asBool())
            @Expect(lifecycleText(fixture.observed()[3], "accept").startsWith("text/event-stream"))
            @Expect(managedRejected(fixture.call("foreign-thread", "foreign-call")))
            @Expect(managedRejected(fixture.call("http-mcp-direct", "no-child-budget", maxCalls: 1)))
            @Expect(fixture.calls(), 1)
            fixture.assertNoSecrets(output: result.output)
        } finally { fixture.close() }
    }

    @TestCase
    func committedApprovalFreezesRealHttpBytesBeforeAnyNetworkWrite(): Unit {
        let fixture = McpHttpProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("http-mcp-approval")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-mcp-approval")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-reject", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Review the exact HTTP MCP call."))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.calls(), 0)
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.calls(), 0)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-approved", fixture.name,
                objectValue([ValueField("text", textValue("approved \"字节\""))]))
            lifecycleTestRequire(session.submit("Approve this frozen HTTP request."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(fixture.calls(), 0)
            @Expect(fixture.childReceipts("completed"), 0)
            lifecycleTestRequire(session.decide(pending.operationId.value, ApprovalDecision.Approve))
            fixture.awaitCalls(1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
            let request = decodeStoredValue(frozen).field("arguments").getOrThrow().field("host_plan").getOrThrow()
                .field("intents").getOrThrow().items[0].field("request").getOrThrow()
            @Expect(lifecycleText(request, "body_hex"), lifecycleText(fixture.observed()[3], "body_hex"))
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM canonical_decision_items") >= 2)
            let output = mcpProductOutput(fixture.database, "http-mcp-approval", "http-approved")
            @Expect(lifecycleText(output, "status"), "complete")
            fixture.assertNoSecrets(output: output)
        } finally { fixture.close() }
    }

    @TestCase
    func activeCancellationAndConfigurationRevocationKeepExactUnknownReceipts(): Unit {
        for (mode in ["cancel", "configuration"]) {
            let fixture = McpHttpProductFixture(mode: "hang")
            try {
                let thread = "http-mcp-" + mode
                @Expect(!managedCompleted(fixture.start(thread)).isError)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId(thread)))
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-hanging", fixture.name, objectValue([]))
                let running = spawn { session.submit("Wait for the actual HTTP MCP response.") }
                try {
                    fixture.awaitCalls(1)
                    @Expect(fixture.childReceipts("completed"), 0)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='executing'"), 2)
                    let started = MonoTime.now()
                    if (mode == "cancel") { lifecycleTestRequire(session.cancel()) }
                    else {
                        let path = fixture.root + "/settings/plugins/services.json"
                        File.writeTo(path, (String.fromUtf8(File.readFrom(path)) + "\n").toArray())
                    }
                    let _ = running.get()
                    @Expect((MonoTime.now() - started).toMilliseconds() < 5000)
                    fixture.awaitClosed(3)
                    fixture.waitReleased()
                    @Expect(!fixture.visible(thread))
                    @Expect(fixture.childReceipts("unknown"), 1)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 2)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
                    @Expect(managedRejected(fixture.call(thread, "never-retry")))
                    @Expect(fixture.calls(), 1)
                    fixture.assertNoSecrets()
                } finally { let _ = session.cancel(); let _ = running.get() }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func refreshRetainsEndpointAndResourceButReplacesOwnedDirectoryAtomically(): Unit {
        let fixture = McpHttpProductFixture(mode: "refresh-change")
        try {
            @Expect(!managedCompleted(fixture.start("http-mcp-refresh")).isError)
            @Expect(!managedCompleted(fixture.call("http-mcp-refresh", "before-refresh")).isError)
            let before = fixture.childArguments("before-refresh").field("binding").getOrThrow()
            let users = fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'")
            let refreshed = managedCompleted(fixture.refresh("http-mcp-refresh"))
            @Expect(!refreshed.isError)
            @Expect(lifecycleText(refreshed.output, "schema"), "axyndra.http-service-refresh-result/v1")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), users)
            @Expect(lifecycleInt(fixture.status("http-mcp-refresh"), "directory_revision", 2147483647), 2)
            let updated = fixture.toolName("remote.updated:雪")
            @Expect(!fixture.visible("http-mcp-refresh"))
            @Expect(fixture.visible("http-mcp-refresh", selected: updated))
            @Expect(managedRejected(fixture.call("http-mcp-refresh", "retired-name")))
            @Expect(!managedCompleted(fixture.call("http-mcp-refresh", "after-refresh", name: updated)).isError)
            let after = fixture.childArguments("after-refresh").field("binding").getOrThrow()
            for (key in ["resource_id", "endpoint_identity", "instance_identity", "grant_digest", "startup_operation_id"]) {
                @Expect(lifecycleText(before, key), lifecycleText(after, key))
            }
            @Expect(lifecycleInt(after, "directory_revision", 2147483647), 2)
            @Expect(lifecycleText(before, "implementation_fingerprint") != lifecycleText(after, "implementation_fingerprint"))
            @Expect(fixture.childReceipts("completed"), 2)
            let maintenance = fixture.database.query("SELECT r.thread_id,r.id,i.provenance FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN items i ON i.id=o.tool_call_item_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                [SqlParameter.Text(PLUGIN_HTTP_REFRESH_TOOL)])
            @Expect(maintenance.size, 1)
            match (effectiveDirectCallOrigin(decodeStoredProvenance(maintenance[0].required(2)))) {
                case DirectCallOrigin.HostService(origin) => @Expect(origin.action, HostServiceAction.Refresh)
                case _ => @Expect(false)
            }
            @Expect(maintenance[0].required(0) != "http-mcp-refresh")
            @Expect(fixture.observed().size, 7)
            @Expect(fixture.calls(), 2)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func responseReflectionAndDisconnectCannotPublishSuccessOrRetry(): Unit {
        for (mode in ["reflect", "disconnect"]) {
            let fixture = McpHttpProductFixture(mode: mode)
            try {
                @Expect(!managedCompleted(fixture.start("http-mcp-failure")).isError)
                let outcome = fixture.call("http-mcp-failure", "http-failed")
                @Expect(outcome.isError())
                @Expect(outcome.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
                @Expect(fixture.calls(), 1)
                @Expect(fixture.childReceipts("unknown"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 2)
                @Expect(!fixture.visible("http-mcp-failure"))
                @Expect(managedRejected(fixture.call("http-mcp-failure", "no-retry")))
                @Expect(fixture.calls(), 1)
                fixture.waitReleased()
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func invalidExplicitTransportNeverFallsBackOrStartsAnyExchange(): Unit {
        let fixture = McpHttpProductFixture()
        try {
            let path = fixture.root + "/settings/plugins/services.json"
            let original = String.fromUtf8(File.readFrom(path))
            for (selector in [textValue("ftp"), integerValue(1), nullValue()]) {
                let changed = parseUnifiedJson(original)
                changed.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow().put("transport", selector)
                File.writeTo(path, stringifyUnifiedJson(changed).toArray())
                let denied = fixture.start("http-invalid-selector")
                @Expect(denied.isError())
                @Expect(denied.error().getOrThrow().code, "plugin.service_transport_unsupported")
                @Expect(fixture.observed().isEmpty())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                @Expect(fixture.product.pluginServiceStatuses().isEmpty())
            }
        } finally { fixture.close() }
    }

    @TestCase
    func httpApprovalFromPriorDirectoryCannotRedirectAfterRefresh(): Unit {
        let fixture = McpHttpProductFixture(mode: "refresh-change", approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("http-stale-prepared")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-stale-prepared")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("stale-http", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Review the original HTTP MCP directory call."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(fixture.calls(), 0)
            @Expect(!managedCompleted(fixture.refresh("http-stale-prepared")).isError)
            let _ = session.decide(pending.operationId.value, ApprovalDecision.Approve)
            @Expect(fixture.calls(), 0)
            @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
            @Expect(lifecycleText(fixture.status("http-stale-prepared"), "state"), "ready")
            @Expect(fixture.visible("http-stale-prepared", selected: fixture.toolName("remote.updated:雪")))
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func installedPackageMutationCannotAuthorizeHttpFromAnUnchangedDescriptor(): Unit {
        let fixture = McpHttpProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("http-changed-package")).isError)
            let packageRoot = productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Root))
            if (!packageRoot.startsWith(fixture.root + "/")) {
                throw IllegalStateException("tamper fixture must own the installed package")
            }
            let completed = fixture.childReceipts("completed")
            let manifest = packageRoot + "/axyndra.plugin.json"
            // Same parsed manifest and pinned descriptor; different installed bytes.
            File.writeTo(manifest, (String.fromUtf8(File.readFrom(manifest)) + "\n").toArray())
            let denied = fixture.call("http-changed-package", "must-not-send")
            @Expect(denied.isError())
            @Expect(fixture.calls(), 0)
            @Expect(fixture.childReceipts("completed"), completed)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
}
