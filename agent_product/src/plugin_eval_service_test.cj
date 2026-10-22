package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// The endpoint and Python runner both come from the installed, digested package.
// No fake process port, interpreter, model decision, operation or Receipt is used.
// Only the existing fixture model selects tools in the Committed approval case.
class EvalServiceProductFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    init(approvalMode!: ApprovalMode = ApprovalMode.Yolo) {
        let created = files
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        try {
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: created.workspace,
                settingsRoot: created.settings, stateRoot: created.root + "/state", fixture: true,
                approvalMode: approvalMode, asyncEnabled: false)))
            openedProduct = Some(product)
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_EVAL_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:eval") { throw IllegalStateException("actual Eval package required") }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let runner = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/runners/python.py"
            if (!exists(Path(runner))) { throw IllegalStateException("packaged Python runner missing") }
            let service = created.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue(runner)]))
            service.put("workspace_mode", textValue("workspace_readwrite"))
            service.put("lifetime_ms", integerValue(180000))
            service.put("max_input_bytes", integerValue(262144))
            let startup = service.field("startup").getOrThrow()
            startup.put("timeout_ms", integerValue(30000))
            startup.put("max_input_bytes", integerValue(4096))
            startup.put("max_output_bytes", integerValue(16384))
            // Arbitrary code is always mutating. No read_only_tools grant.
            let document = created.document(service: Some(service))
            let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
            plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            plugin.put("configuration", objectValue([ValueField("version", integerValue(1)),
                ValueField("language", textValue("py")), ValueField("max_timeout_ms", integerValue(30000))]))
            created.write(document)
            database = SqliteDatabase(created.root + "/state/state.db")
            openedDatabase = Some(database)
        } catch (error: Exception) {
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            created.close(); throw error
        }
    }
    prop name: String { get() { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio.eval" } }
    func start(thread: String): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session",
            approvalDecision: ApprovalDecision.Approve, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func input(code: String, reset!: Bool = false): AgentValue {
        objectValue([ValueField("language", textValue("py")), ValueField("code", textValue(code)), ValueField("reset", boolValue(reset))])
    }
    func call(thread: String, callId: String, input: AgentValue,
        capabilities!: CapabilitySet = productCapabilities()): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), capabilities, ToolCall(callId, name, input),
            budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
    }
    func childReceipts(): Int64 {
        database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operation_effect_records effect " +
            "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=? AND receipt.outcome='completed'",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)]).size
    }
    func awaitChildReceipt(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (childReceipts() == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (childReceipts() != 1) { throw IllegalStateException("actual cell write receipt missing") }
    }
    func visible(thread: String): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == name) { return true }
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
        throw IllegalStateException("Eval service retains actual cleanup ownership")
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        var closed = false
        while (!closed && MonoTime.now() < deadline) {
            closed = product.close().isOk()
            if (!closed) { sleep(Duration.millisecond * 10) }
        }
        if (!closed) { throw IllegalStateException("Eval fixture did not acknowledge native cleanup") }
        database.close(); files.close()
    }
}

func evalServiceCell(result: Result<ToolInvocationResult>): AgentValue {
    let value = managedCompleted(result)
    if (lifecycleText(value.output, "status") != "complete") { throw IllegalStateException("cell has no observed completion") }
    value.output.field("result").getOrThrow()
}

func evalServiceTestHex(source: String): String {
    let alphabet = "0123456789abcdef".toArray()
    let output = ArrayList<Byte>()
    for (byte in source.toArray()) {
        let value = UInt32(byte)
        output.add(alphabet[Int64((value >> 4) & 15)])
        output.add(alphabet[Int64(value & 15)])
    }
    String.fromUtf8(output.toArray())
}

func evalServiceCommittedOutput(database: SqliteDatabase, thread: String, call: String): AgentValue {
    for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(thread)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, output, isError) =>
                if (id.value == call) {
                    if (isError) { throw IllegalStateException("actual Eval canonical result is an error") }
                    return output
                }
            case _ => ()
        }
    }
    throw IllegalStateException("actual Eval canonical result is missing")
}

@Test
class PluginEvalServiceTests {
    @TestCase
    func directCellsPersistResetAndRemainPrivateToActualServiceInstances(): Unit {
        let fixture = EvalServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("eval-one")).isError)
            @Expect(!managedCompleted(fixture.start("eval-two")).isError)
            @Expect(fixture.childReceipts(), 0)
            let first = evalServiceCell(fixture.call("eval-one", "first", fixture.input("counter = 40\ncounter")))
            @Expect(lifecycleText(first, "stdout").trimAscii(), "40")
            let isolated = evalServiceCell(fixture.call("eval-two", "same-call-id", fixture.input("'counter' in globals()")))
            @Expect(lifecycleText(isolated, "stdout").trimAscii(), "false")
            let increment = evalServiceCell(fixture.call("eval-one", "same-call-id", fixture.input("counter += 2\ncounter")))
            @Expect(lifecycleText(increment, "stdout").trimAscii(), "42")
            let reset = evalServiceCell(fixture.call("eval-one", "reset", fixture.input("'counter' in globals()", reset: true)))
            @Expect(lifecycleText(reset, "stdout").trimAscii(), "false")
            @Expect(reset.field("reset").getOrThrow().asBool())
            let failed = managedCompleted(fixture.call("eval-one", "known-error", fixture.input("print('observed')\nraise ValueError('cell failure')")))
            @Expect(failed.isError); @Expect(lifecycleText(failed.output, "status"), "complete")
            @Expect(lifecycleText(failed.output.field("result").getOrThrow(), "stdout").contains("observed"))
            let next = evalServiceCell(fixture.call("eval-one", "after-error", fixture.input("6 * 7")))
            @Expect(lifecycleText(next, "stdout").trimAscii(), "42")
            @Expect(fixture.childReceipts(), 6)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 6)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func committedMutationRequiresApprovalAndExecutesOnlyTheUnchangedCell(): Unit {
        let fixture = EvalServiceProductFixture(approvalMode: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("eval-approval")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("eval-approval")))
            let input = fixture.input("from pathlib import Path\nPath('eval-approved.txt').write_text('literal 雪 $(never shell)', encoding='utf-8')\n'cell complete'")
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("eval-rejected", fixture.name, input)
            lifecycleTestRequire(session.submit("Prepare the requested Python cell."))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.childReceipts(), 0)
            @Expect(!exists(Path(fixture.files.workspace + "/eval-approved.txt")))
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.childReceipts(), 0)
            @Expect(!exists(Path(fixture.files.workspace + "/eval-approved.txt")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("eval-approved", fixture.name, input)
            lifecycleTestRequire(session.submit("Approve the exact prepared Python cell."))
            let approval = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0)
            @Expect(fixture.childReceipts(), 0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/eval-approved.txt")), "literal 雪 $(never shell)")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0), frozen)
            @Expect(fixture.database.query("SELECT effect_class,retry_disposition FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0), "external_mutation")
            @Expect(fixture.database.query("SELECT retry_disposition FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0), "never")
            let plan = decodeStoredValue(frozen).field("arguments").getOrThrow().field("host_plan").getOrThrow()
            let bytes = lifecycleTestRequire(channelServiceWriteBytes(plan.field("intents").getOrThrow().items[0]))
            @Expect(String.fromUtf8(bytes), "30000|0|" + evalServiceTestHex(lifecycleText(input, "code")) + "\n")
            let output = evalServiceCommittedOutput(fixture.database, "eval-approval", "eval-approved")
            @Expect(lifecycleText(output, "status"), "complete")
            @Expect(lifecycleText(output.field("result").getOrThrow(), "stdout").contains("cell complete"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") > 0)
        } finally { fixture.close() }
    }

    @TestCase
    func cancelAfterApprovedWriteStopsEscapedDescendantAndNeverReplays(): Unit {
        let fixture = EvalServiceProductFixture(approvalMode: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("eval-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("eval-cancel")))
            let code = "import os, signal, time\npid = os.fork()\nif pid == 0:\n" +
                " os.setsid()\n signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" +
                " while True:\n  with open('eval-heartbeat', 'ab') as f: f.write(b'.')\n  time.sleep(0.02)\n" +
                "open('eval-parent-ready', 'w').write(str(pid))\nwhile True: time.sleep(0.02)"
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("eval-hang", fixture.name, fixture.input(code))
            lifecycleTestRequire(session.submit("Run the long Python cell after approval."))
            let approval = session.approval().getOrThrow()
            @Expect(fixture.childReceipts(), 0)
            let running = spawn { session.decide(approval.operationId.value, ApprovalDecision.Approve) }
            try {
                rawChannelAwaitFile(fixture.files.workspace + "/eval-parent-ready")
                rawChannelAwaitFile(fixture.files.workspace + "/eval-heartbeat")
                fixture.awaitChildReceipt()
                lifecycleTestRequire(session.cancel())
                let _ = running.get()
                fixture.waitReleased()
                let heartbeat = fixture.files.workspace + "/eval-heartbeat"
                let stopped = FileInfo(heartbeat).size
                @Expect(stopped > 0)
                sleep(Duration.millisecond * 200)
                @Expect(FileInfo(heartbeat).size, stopped)
                @Expect(fixture.childReceipts(), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(!fixture.visible("eval-cancel"))
                @Expect(managedRejected(fixture.call("eval-cancel", "no-replay", fixture.input(code))))
                @Expect(fixture.childReceipts(), 1)
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }

    @TestCase
    func languageTimeoutLowCapabilitiesAndDisabledCatalogCannotWriteCells(): Unit {
        let fixture = EvalServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("eval-boundaries")).isError)
            let language = fixture.input("1"); language.put("language", textValue("rb"))
            @Expect(managedRejected(fixture.call("eval-boundaries", "wrong-language", language)))
            let timeout = fixture.input("1"); timeout.put("timeout", integerValue(0))
            @Expect(managedRejected(fixture.call("eval-boundaries", "unbounded-timeout", timeout)))
            @Expect(managedRejected(fixture.call("eval-boundaries", "low-cap", fixture.input("1"),
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]))))
            @Expect(managedRejected(fixture.call("other-thread", "cross-thread", fixture.input("1"))))
            @Expect(fixture.childReceipts(), 0)
            @Expect(!managedCompleted(fixture.call("eval-boundaries", "actual", fixture.input("1"))).isError)
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("eval-boundaries"))
            @Expect(managedRejected(fixture.call("eval-boundaries", "disabled", fixture.input("1"))))
            @Expect(fixture.childReceipts(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func eofOrOversizeAfterRealCellWriteRetainsUnknownAndRevokesTheService(): Unit {
        for (code in ["import os; os._exit(0)", "print('x' * 100000)"]) {
            let fixture = EvalServiceProductFixture()
            try {
                @Expect(!managedCompleted(fixture.start("eval-unknown")).isError)
                let result = fixture.call("eval-unknown", "actual-unknown", fixture.input(code))
                @Expect(result.isError())
                if (result.isError()) { @Expect(result.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired) }
                fixture.waitReleased()
                @Expect(fixture.childReceipts(), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(!fixture.visible("eval-unknown"))
                @Expect(managedRejected(fixture.call("eval-unknown", "no-retry", fixture.input(code))))
                @Expect(fixture.childReceipts(), 1)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func installedPackagePublishesOnlyAfterActualServiceStartAndWithdrawsOnDisable(): Unit {
        let fixture = EvalServiceProductFixture()
        try {
            @Expect(!fixture.visible("eval-publication"))
            @Expect(fixture.product.pluginServiceStatuses().size, 0)
            for (definition in fixture.product.tools(threadId: Some(ThreadId("eval-publication")))) {
                @Expect(definition.name != "eval")
            }
            let missing = hostServiceEntryCompleted(fixture.call("eval-publication", "before-service", fixture.input("6 * 7")))
            @Expect(missing.isError, true)
            @Expect(missing.output.field("error").getOrThrow().text, "tool.not_found")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='eval-publication' AND state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='eval-publication' AND kind='user_message'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='eval-publication' AND kind='tool_call'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations operation JOIN runs run ON run.id=operation.run_id WHERE run.thread_id='eval-publication'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='eval-publication' AND kind='operation_execution_handoff'"), 0)
            @Expect(fixture.childReceipts(), 0)
            @Expect(!managedCompleted(fixture.start("eval-publication")).isError)
            @Expect(fixture.visible("eval-publication"))
            @Expect(!fixture.visible("eval-other-thread"))
            var actualSchema = false
            for (definition in fixture.product.tools(threadId: Some(ThreadId("eval-publication"))) where definition.name == fixture.name) {
                let properties = definition.inputSchema.field("properties").getOrThrow()
                @Expect(properties.field("language").getOrThrow().field("enum").getOrThrow().items[0].text, "py")
                @Expect(properties.field("code").getOrThrow().field("type").getOrThrow().text, "string")
                @Expect(properties.field("timeout").getOrThrow().field("minimum").getOrThrow().asNumberText(), "1")
                @Expect(properties.field("timeout").getOrThrow().field("maximum").getOrThrow().asNumberText(), "30")
                @Expect(definition.inputSchema.field("additionalProperties").getOrThrow().asBool(), false)
                actualSchema = true
            }
            @Expect(actualSchema)
            let observed = evalServiceCell(fixture.call("eval-publication", "actual-service", fixture.input("6 * 7")))
            @Expect(lifecycleText(observed, "stdout").trimAscii(), "42")
            @Expect(fixture.childReceipts(), 1)
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("eval-publication"))
            @Expect(managedRejected(fixture.call("eval-publication", "after-disable", fixture.input("6 * 7"))))
            @Expect(fixture.childReceipts(), 1)
            for (definition in fixture.product.tools(threadId: Some(ThreadId("eval-publication")))) {
                @Expect(definition.name != "eval")
            }
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

}
