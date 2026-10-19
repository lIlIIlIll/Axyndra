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
// LSP client, internal manager, model decision, channel or Operation authority.
class LspProductFixture {
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
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_LSP_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:lsp") { throw IllegalStateException("installed standalone LSP artifact required") }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let peer = files.external + "/lsp-peer.py"
            File.writeTo(peer, File.readFrom(getVariable("AXYNDRA_LSP_TEST_SERVER").getOrThrow()))
            transcript = files.workspace + "/actual-lsp.jsonl"
            File.writeTo(transcript, "".toArray()); File.writeTo(transcript + ".frames", "".toArray())
            uri = "file://" + files.workspace + "/main.py"
            File.writeTo(files.workspace + "/main.py", "unchanged on disk".toArray())
            let service = files.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue(peer), textValue(transcript)]))
            service.put("read_only_mounts", listValue([textValue(files.external)]))
            // Only the backend's bounded fixture transcript uses this write
            // mount. The installed language endpoint has no filesystem mount.
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
            plugin.put("configuration", objectValue([ValueField("version", integerValue(1)), ValueField("root_uri", textValue("file://" + files.workspace)),
                ValueField("language_id", textValue("python")), ValueField("initialization_options", objectValue([])),
                ValueField("settings", objectValue([])), ValueField("request_timeout_ms", integerValue(10000))]))
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
    func input(text: String, version!: Int64 = 1): AgentValue {
        objectValue([ValueField("documents", listValue([objectValue([ValueField("uri", textValue(uri)), ValueField("version", integerValue(version)),
            ValueField("text", textValue(text))])])), ValueField("params", objectValue([ValueField("textDocument", objectValue([ValueField("uri", textValue(uri))])),
            ValueField("position", objectValue([ValueField("line", integerValue(0)), ValueField("character", integerValue(0))]))])), ValueField("method", textValue(""))])
    }
    func call(thread: String, id: String, action: String, input: AgentValue, maxCalls!: Int64 = 2): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), productCapabilities(), ToolCall(id, name(action), input),
            budget: ExecutionBudget(maxToolCalls: maxCalls, maxConcurrentTools: 1))
    }
    func observed(): Array<AgentValue> {
        let bytes = File.readFrom(transcript)
        if (bytes.size > 16777216) { throw IllegalStateException("LSP fixture transcript bound") }
        let lines = String.fromUtf8(bytes).split("\n"); let values = ArrayList<AgentValue>()
        for (index in 0..lines.size - 1 where lines[index] != "") { values.add(parseUnifiedJson(lines[index], maxBytes: 8388608)) }
        values.toArray()
    }
    func methodCount(method: String): Int64 { var count: Int64 = 0; for (value in observed() where lifecycleText(value, "method") == method) { count += 1 }; count }
    func childReceipts(outcome: String): Int64 {
        let rows = database.query("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id=? AND r.outcome=?",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL), SqlParameter.Text(outcome)])
        if (rows.size != 1 || rows[0].size != 1) { throw IllegalStateException("exact child Receipt count required") }
        Int64.parse(rows[0].required(0))
    }
    func awaitMethod(method: String, count: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 15
        while (methodCount(method) < count && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (methodCount(method) != count) { throw IllegalStateException("LSP peer did not observe exact method count") }
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        while (!product.close().isOk()) {
            if (MonoTime.now() >= deadline) { throw IllegalStateException("LSP native cleanup acknowledgment missing") }
            sleep(Duration.millisecond * 10)
        }
        database.close(); files.close()
    }

    func visible(thread: String, action: String): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == name(action)) { return true }
        false
    }
    func waitReleased(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (MonoTime.now() < deadline) {
            var held = false
            for (status in product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()) { held = true }
            if (!held) { return }
            sleep(Duration.millisecond * 10)
        }
        throw IllegalStateException("LSP service retains actual cleanup ownership")
    }
}

@Test
class PluginLspServiceTests {
    @TestCase
    func installedLanguageInitializesAndFreezesDocumentBatchInOneRealChild(): Unit {
        let fixture = LspProductFixture()
        try {
            @Expect(fixture.product.unregisterTool("bash")); @Expect(fixture.product.unregisterTool("bash_readonly"))
            @Expect(!managedCompleted(fixture.start("lsp-direct")).isError)
            @Expect(fixture.methodCount("initialize"), 1); @Expect(fixture.methodCount("initialized"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let result = managedCompleted(fixture.call("lsp-direct", "lsp-hover", "hover", fixture.input("first 雪")))
            @Expect(!result.isError)
            let data = result.output.field("result").getOrThrow()
            @Expect(data.field("value").getOrThrow().field("contents").getOrThrow().text, "first 雪")
            @Expect(data.field("notifications").getOrThrow().field("events").getOrThrow().items.size, 1)
            @Expect(fixture.childReceipts("completed"), 1)
            let rows = fixture.database.query("SELECT e.normalized_plan,a.request_key FROM operation_effect_records e " +
                "JOIN derived_operation_admissions a ON a.operation_id=e.operation_id WHERE e.tool_id=?", [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
            @Expect(rows.size, 1); @Expect(rows[0].required(1), "channel-service:lsp-hover:lsp-call")
            let arguments = decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow()
            let _ = lifecycleTestRequire(channelServiceWriteBytes(arguments.field("intent").getOrThrow()))
            let frames = String.fromUtf8(File.readFrom(fixture.transcript + ".frames")).split("\n")
            @Expect(lifecycleText(arguments.field("intent").getOrThrow(), "bytes_hex"), frames[2] + frames[3])
            let changed = managedCompleted(fixture.call("lsp-direct", "lsp-changed", "hover", fixture.input("changed", version: 2)))
            @Expect(changed.output.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text, "changed")
            @Expect(fixture.methodCount("textDocument/didOpen"), 1); @Expect(fixture.methodCount("textDocument/didChange"), 1)
            @Expect(fixture.childReceipts("completed"), 2)
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/main.py")), "unchanged on disk")
        } finally { fixture.close() }
    }

    @TestCase
    func actualCommittedApprovalKeepsPurePreparationAndExactDocumentBytes(): Unit {
        let fixture = LspProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(managedRejected(fixture.start("lsp-approved", decision: ApprovalDecision.Reject)))
            @Expect(fixture.observed().isEmpty())
            @Expect(!managedCompleted(fixture.start("lsp-approved")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-approved")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("lsp-approved-hover", fixture.name("hover"), fixture.input("approved only"))
            lifecycleTestRequire(session.submit("Review this frozen language request."))
            let approval = session.approval().getOrThrow()
            @Expect(fixture.methodCount("textDocument/didOpen"), 0); @Expect(fixture.methodCount("textDocument/hover"), 0)
            @Expect(fixture.childReceipts("completed"), 0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            fixture.awaitMethod("textDocument/hover", 1)
            let output = mcpProductOutput(fixture.database, "lsp-approved", "lsp-approved-hover")
            @Expect(output.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text, "approved only")
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM canonical_decision_items") > 0)
        } finally { fixture.close() }
    }

    @TestCase
    func explicitPayloadProfileKeepsThreeMibDocumentAndResultInCanonicalHistory(): Unit {
        let fixture = LspProductFixture(payload: true)
        try {
            @Expect(!managedCompleted(fixture.start("lsp-large")).isError)
            let expected = String.fromUtf8(Array<Byte>(3145728, repeat: b'x'))
            let result = managedCompleted(fixture.call("lsp-large", "lsp-large-hover", "hover", fixture.input(expected)))
            @Expect(!result.isError)
            let stored = mcpProductOutput(fixture.database, "lsp-large", "lsp-large-hover")
            @Expect(stored.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text, expected)
            @Expect(encodeStoredValue(stored).size > 6291456)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func actualCommittedCancellationKeepsWrittenRequestUnknownAndClosesService(): Unit {
        let fixture = LspProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("lsp-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-cancel")))
            let input = objectValue([ValueField("documents", listValue([])), ValueField("params", objectValue([])), ValueField("method", textValue("fixture/hang"))])
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("lsp-hanging", fixture.name("request"), input)
            let running = spawn { session.submit("Wait for the real language server.") }
            try {
                fixture.awaitMethod("fixture/hang", 1)
                let deadline = MonoTime.now() + Duration.second * 5
                while (fixture.childReceipts("completed") == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(fixture.childReceipts("completed"), 1)
                lifecycleTestRequire(session.cancel()); let _ = running.get()
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='lsp-cancel' AND state='cancelled'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing')"), 0)
                @Expect(fixture.methodCount("$/cancelRequest"), 0)
                @Expect(managedRejected(fixture.call("lsp-cancel", "no-retry", "request", input)))
                @Expect(fixture.methodCount("fixture/hang"), 1)
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }
    @TestCase
    func languageWorkspaceEditGeneratesOwnedPlanAndRequiresIndependentApplyApprovalAfterRestart(): Unit {
        let fixture = LspProductFixture()
        var reopened: ?ProductRuntime = None
        try {
            @Expect(!managedCompleted(fixture.start("lsp-edit")).isError)
            let before = "original\n"; let after = "renamedriginal\n"
            File.writeTo(fixture.files.workspace + "/main.py", before.toArray())
            let input = fixture.input(before); input.field("params").getOrThrow().put("newName", textValue("renamed"))
            let result = managedCompleted(fixture.call("lsp-edit", "lsp-rename", "rename", input, maxCalls: 3))
            @Expect(!result.isError)
            let summary = result.output.field("result").getOrThrow().field("application_plan").getOrThrow()
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/main.py")), before)
            @Expect(fixture.childReceipts("completed"), 1)
            let proposals = fixture.database.query("SELECT e.normalized_plan,r.outcome FROM operation_effect_records e " +
                "JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id='host.file.plan.propose'")
            @Expect(proposals.size, 1); @Expect(proposals[0].required(1), "completed")
            let source = summary.field("source").getOrThrow()
            @Expect(lifecycleText(source, "contribution"), fixture.name("rename"))
            @Expect(lifecycleText(source, "parent_implementation_fingerprint").startsWith("owned-v1:"))
            @Expect(decodeStoredValue(proposals[0].required(0)).field("arguments").getOrThrow().field("managed_binding").isSome())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let deadline = MonoTime.now() + Duration.second * 10
            while (!fixture.product.close().isOk()) {
                if (MonoTime.now() >= deadline) { throw IllegalStateException("LSP pre-restart cleanup acknowledgment missing") }
                sleep(Duration.millisecond * 10)
            }
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: fixture.files.workspace,
                settingsRoot: fixture.files.settings, stateRoot: fixture.files.root + "/state", fixture: true,
                approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
            reopened = Some(product)
            let session = product.applicationSession(sessionId: Some(SessionId("lsp-independent-apply")))
            let arguments = objectValue([ValueField("plan_ref", summary.field("plan_ref").getOrThrow()),
                ValueField("plan_digest", summary.field("plan_digest").getOrThrow())])
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("lsp-apply", "apply_file_plan", arguments)
            lifecycleTestRequire(session.submit("Review the exact generated file change before applying it."))
            let approval = session.approval().getOrThrow()
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/main.py")), before)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/main.py")), after)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id WHERE e.tool_id='apply_file_plan' AND r.outcome='completed'"), 1)
        } finally {
            match (reopened) { case Some(value) => let _ = value.close(); case None => () }
            fixture.close()
        }
    }

    @TestCase
    func installedLanguagePublishesOnlyAfterActualServiceStartAndWithdrawsOnDisable(): Unit {
        let fixture = LspProductFixture()
        try {
            for (definition in fixture.product.tools()) { @Expect(definition.name != "lsp") }
            @Expect(!fixture.visible("lsp-publication", "hover"))
            @Expect(fixture.product.pluginServiceStatuses().size, 0)
            let missingPackage = fixture.product.startPluginService(SessionId("lsp-service-missing"),
                "axyndra:lsp-not-installed", "stdio", "session", approvalDecision: ApprovalDecision.Approve,
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
            @Expect(missingPackage.isError())
            @Expect(missingPackage.error().getOrThrow().code, "plugin.not_found")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='lsp-service-missing'"), 0)
            let missing = hostServiceEntryCompleted(fixture.call("lsp-publication", "before-start", "hover", fixture.input("not executed")))
            @Expect(missing.isError, true)
            @Expect(missing.output.field("error").getOrThrow().text, "tool.not_found")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='lsp-publication' AND state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='lsp-publication' AND kind='user_message'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='lsp-publication' AND kind='tool_call'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations operation JOIN runs run ON run.id=operation.run_id WHERE run.thread_id='lsp-publication'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='lsp-publication' AND kind='operation_execution_handoff'"), 0)
            @Expect(fixture.observed().size, 0)
            @Expect(fixture.childReceipts("completed"), 0)
            @Expect(!managedCompleted(fixture.start("lsp-publication")).isError)
            @Expect(fixture.visible("lsp-publication", "hover"))
            @Expect(!fixture.visible("lsp-another-thread", "hover"))
            var actualSchema = false
            for (definition in fixture.product.tools(threadId: Some(ThreadId("lsp-publication"))) where definition.name == fixture.name("hover")) {
                let properties = definition.inputSchema.field("properties").getOrThrow()
                @Expect(properties.field("documents").getOrThrow().field("type").getOrThrow().text, "array")
                @Expect(properties.field("params").getOrThrow().field("type").getOrThrow().text, "object")
                @Expect(properties.field("action").isNone())
                @Expect(definition.inputSchema.field("additionalProperties").getOrThrow().asBool(), false)
                actualSchema = true
            }
            @Expect(actualSchema)
            let actual = managedCompleted(fixture.call("lsp-publication", "actual-hover", "hover", fixture.input("published 雪")))
            @Expect(!actual.isError)
            @Expect(actual.output.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text, "published 雪")
            @Expect(fixture.methodCount("initialize"), 1)
            @Expect(fixture.methodCount("textDocument/hover"), 1)
            @Expect(fixture.childReceipts("completed"), 1)
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("lsp-publication", "hover"))
            @Expect(managedRejected(fixture.call("lsp-publication", "after-disable", "hover", fixture.input("must not execute"))))
            @Expect(fixture.methodCount("textDocument/hover"), 1)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing')"), 0)
        } finally { fixture.close() }
    }

}
