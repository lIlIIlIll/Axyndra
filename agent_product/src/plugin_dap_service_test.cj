package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// An installed native package and public Product lifecycle entry, never a fake
// DAP client, internal manager, model decision, channel or Operation authority.
class DapProductFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let transcript: String
    let uri: String
    init(approval!: ApprovalMode = ApprovalMode.Yolo, payload!: Bool = false) {
        var opened: ?ProductRuntime = None; var connected: ?SqliteDatabase = None
        try {
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
                settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
                approvalMode: approval, asyncEnabled: false)))
            opened = Some(product)
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_DAP_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:dap") { throw IllegalStateException("installed standalone DAP artifact required") }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let peer = files.external + "/dap-peer.py"
            File.writeTo(peer, File.readFrom(getVariable("AXYNDRA_DAP_TEST_SERVER").getOrThrow()))
            transcript = files.workspace + "/actual-dap.jsonl"
            File.writeTo(transcript, "".toArray()); File.writeTo(transcript + ".frames", "".toArray())
            uri = "file://" + files.workspace + "/main.py"
            File.writeTo(files.workspace + "/main.py", "unchanged on disk".toArray())
            let service = files.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue(peer), textValue(transcript)]))
            service.put("read_only_mounts", listValue([textValue(files.external)]))
            // Only the backend's bounded fixture transcript uses this write
            // mount. The installed debug endpoint has no filesystem mount.
            service.put("workspace_mode", textValue("workspace_readwrite"))
            service.put("lifetime_ms", integerValue(180000))
            service.put("max_input_bytes", integerValue(16777216)); service.put("max_output_bytes", integerValue(16777216))
            let resources = service.field("resources").getOrThrow()
            resources.put("max_output_bytes", integerValue(16777216)); resources.put("file_size_bytes", integerValue(16777216))
            let startup = service.field("startup").getOrThrow()
            startup.put("timeout_ms", integerValue(30000)); startup.put("max_input_bytes", integerValue(65536))
            startup.put("max_output_bytes", integerValue(65536)); startup.put("max_writes", integerValue(8))
            if (payload) {
                service.put("protocol_limits", capacityTestProfile())
                service.put("payload_limits", objectValue([ValueField("version", integerValue(1)),
                    ValueField("max_message_bytes", integerValue(16777216)), ValueField("max_input_bytes", integerValue(4194304)),
                    ValueField("max_prepare_bytes", integerValue(8388608)), ValueField("max_result_bytes", integerValue(8388608)),
                    ValueField("max_write_bytes", integerValue(4128768))]))
            }
            let document = files.document(service: Some(service)); let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))); plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            plugin.put("configuration", objectValue([ValueField("version", integerValue(1)), ValueField("adapter_id", textValue("fixture")), ValueField("initialization", objectValue([])), ValueField("request_timeout_ms", integerValue(10000))]))
            files.write(document)
            database = SqliteDatabase(files.root + "/state/state.db"); connected = Some(database)
        } catch (error: Exception) {
            try { match (opened) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (connected) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            files.close(); throw error
        }
    }
    func name(action: String): String { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio." + action }
    func start(thread: String, decision!: ApprovalDecision = ApprovalDecision.Approve): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session", approvalDecision: decision,
            budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func input(arguments: AgentValue, command!: String = "", following!: Array<AgentValue> = []): AgentValue {
        objectValue([ValueField("arguments", arguments), ValueField("command", textValue(command)), ValueField("following_requests", listValue(following))])
    }
    func call(thread: String, id: String, action: String, input: AgentValue, maxCalls!: Int64 = 2): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), productCapabilities(), ToolCall(id, name(action), input),
            budget: ExecutionBudget(maxToolCalls: maxCalls, maxConcurrentTools: 1))
    }
    func observed(): Array<AgentValue> {
        let bytes = File.readFrom(transcript)
        if (bytes.size > 16777216) { throw IllegalStateException("DAP fixture transcript bound") }
        let lines = String.fromUtf8(bytes).split("\n"); let values = ArrayList<AgentValue>()
        for (index in 0..lines.size - 1 where lines[index] != "") { values.add(parseUnifiedJson(lines[index], maxBytes: 8388608)) }
        values.toArray()
    }
    func commandCount(method: String): Int64 { var count: Int64 = 0; for (value in observed() where lifecycleText(value, "command") == method) { count += 1 }; count }
    func childReceipts(outcome: String): Int64 {
        let rows = database.query("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id=? AND r.outcome=?",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL), SqlParameter.Text(outcome)])
        if (rows.size != 1 || rows[0].size != 1) { throw IllegalStateException("exact child Receipt count required") }
        Int64.parse(rows[0].required(0))
    }
    func awaitCommand(method: String, count: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 15
        while (commandCount(method) < count && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (commandCount(method) != count) { throw IllegalStateException("DAP peer did not observe exact method count") }
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        while (!product.close().isOk()) {
            if (MonoTime.now() >= deadline) { throw IllegalStateException("DAP native cleanup acknowledgment missing") }
            sleep(Duration.millisecond * 10)
        }
        database.close(); files.close()
    }
}

@Test
class PluginDapServiceTests {
    @TestCase
    func actualLaunchConfigurationAndEventsShareOneFrozenChildWrite(): Unit {
        let fixture = DapProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("dap-launch")).isError)
            let input = fixture.input(objectValue([ValueField("program", textValue("/fixture/program"))]),
                following: [objectValue([ValueField("command", textValue("setBreakpoints")), ValueField("arguments", objectValue([
                    ValueField("source", objectValue([ValueField("path", textValue("/fixture/main.py"))])),
                    ValueField("breakpoints", listValue([objectValue([ValueField("line", integerValue(1))])]))]))]),
                    objectValue([ValueField("command", textValue("configurationDone")), ValueField("arguments", objectValue([]))])])
            let result = managedCompleted(fixture.call("dap-launch", "launch-debuggee", "launch", input))
            @Expect(!result.isError)
            @Expect(result.output.field("result").getOrThrow().field("responses").getOrThrow().items[0].field("started").getOrThrow().asBool(), true)
            @Expect(fixture.commandCount("launch"), 1); @Expect(fixture.commandCount("configurationDone"), 1)
            @Expect(fixture.childReceipts("completed"), 1)
            let rows = fixture.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id='host.process.channel.write'")
            @Expect(rows.size, 1)
            let exact = decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow().field("intent").getOrThrow().field("bytes_hex").getOrThrow().text
            let frames = String.fromUtf8(File.readFrom(fixture.transcript + ".frames")).split("\n")
            @Expect(exact, frames[1] + frames[2] + frames[3])
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }
    @TestCase
    func actualCommittedEvaluationWaitsForIndependentRootApproval(): Unit {
        let fixture = DapProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("dap-approval")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("dap-approval")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("evaluate-approved", fixture.name("evaluate"),
                fixture.input(objectValue([ValueField("expression", textValue("42"))])))
            lifecycleTestRequire(session.submit("Evaluate the expression in the actual debugger."))
            @Expect(fixture.commandCount("evaluate"), 0); @Expect(fixture.childReceipts("completed"), 0)
            let approval = session.approval().getOrThrow()
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            @Expect(fixture.commandCount("evaluate"), 1); @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { fixture.close() }
    }
    @TestCase
    func largePreparedEvaluationKeepsCompleteCanonicalResult(): Unit {
        let fixture = DapProductFixture(payload: true)
        try {
            @Expect(!managedCompleted(fixture.start("dap-large")).isError)
            let expected = String.fromUtf8(Array<Byte>(3145728, repeat: b'x'))
            let result = managedCompleted(fixture.call("dap-large", "large-evaluate", "evaluate",
                fixture.input(objectValue([ValueField("expression", textValue(expected))]))))
            @Expect(!result.isError)
            @Expect(result.output.field("result").getOrThrow().field("responses").getOrThrow().items[0].field("result").getOrThrow().text, expected)
            let rows = fixture.database.query("SELECT r.detail FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id='" + fixture.name("evaluate") + "'")
            @Expect(rows.size, 1)
            let detail = decodeStoredValue(rows[0].required(0))
            @Expect(detail.field("output").getOrThrow().field("result").getOrThrow().field("responses").getOrThrow().items[0].field("result").getOrThrow().text, expected)
            @Expect(rows[0].required(0).size > 6291456)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 1)
        } finally { fixture.close() }
    }
    @TestCase
    func actualCancelRetainsUnknownAfterWrittenRequest(): Unit {
        let fixture = DapProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("dap-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("dap-cancel")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("hang-debugger", fixture.name("custom_request"), fixture.input(objectValue([]), command: "fixture/hang"))
            let running = spawn { session.submit("Wait for the actual debugger request.") }
            try {
                fixture.awaitCommand("fixture/hang", 1)
                let deadline = MonoTime.now() + Duration.second * 5
                while (fixture.childReceipts("completed") == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(fixture.childReceipts("completed"), 1)
                lifecycleTestRequire(session.cancel()); let _ = running.get()
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='dap-cancel' AND state='cancelled'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing')"), 0)
                @Expect(fixture.commandCount("cancel"), 0)
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }
    @TestCase
    func reverseProcessRequestCannotBorrowStartupGrant(): Unit {
        let fixture = DapProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("dap-reverse")).isError)
            let call = fixture.call("dap-reverse", "reverse-launch", "custom_request", fixture.input(objectValue([]), command: "fixture/runInTerminal"))
            @Expect(managedRejected(call))
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.plugin.lifecycle.start'"), 1)
            for (item in fixture.observed()) { @Expect(lifecycleText(item, "type"), "request") }
            @Expect(managedRejected(fixture.call("dap-reverse", "no-retry", "threads", fixture.input(objectValue([])))))
        } finally { fixture.close() }
    }
}
