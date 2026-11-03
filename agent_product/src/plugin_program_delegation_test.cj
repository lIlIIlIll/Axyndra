package agent_product

import agent_plugin_registry

import std.convert.*

import agent_domain.*
import agent_ports.*
import std.convert.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ProgramDelegationFixture {
    let root: String
    let product: ProductRuntime
    let record: ProductPluginRecord
    let workspace: ProductPluginRecord
    let database: SqliteDatabase
    init(mode!: ApprovalMode = ApprovalMode.Yolo, target!: String = "read", filePlanProposals!: ?Bool=None, inputAttachment!: Bool=false) {
        let directory = pluginContractTemp("program-delegation")
        Directory.create(directory + "/workspace", recursive: true)
        File.writeTo(directory + "/workspace/first.txt", "before\n".toArray())
        File.writeTo(directory + "/outside.txt", "private outside\n".toArray())
        let opened = workspacePluginOpen(directory, mode)
        var db: ?SqliteDatabase = None
        try {
            let resources = workspacePluginInstall(opened, directory)
            let installed = match (opened.importLocalPlugin(getVariable("AXYNDRA_PROGRAM_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
                case PluginRegistryResult.Ok(value) => value; case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            if (productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:program") { throw IllegalStateException("actual independent Program package required") }
            match (opened.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
                case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(directory + "/settings/plugins/services.json")))
            let entries = ArrayList<AgentValue>(document.field("plugins").getOrThrow().items.toArray())
            entries.add(objectValue([ValueField("namespace", textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest", textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.ContentDigest)))), ValueField("configuration", objectValue([])),
                ValueField("requests", listValue([])), ValueField("credentials", listValue([])),
                ValueField("tool_delegations", listValue([objectValue([ValueField("contribution", textValue("run")),
                    ValueField("max_calls", integerValue(32)), ValueField("max_depth", integerValue(2)),
                    ValueField("tools", listValue([objectValue([ValueField("alias", textValue("read")),
                        ValueField("plugin", textValue(productRegistryCopyText83(resources.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("contribution", textValue(target))])]))])]))]))
            match(filePlanProposals){case Some(value)=>entries[entries.size-1].field("tool_delegations").getOrThrow()
                .items[0].put("file_plan_proposals",boolValue(value));case None=>()}
            if (inputAttachment) { entries[entries.size-1].put("tool_input_attachments", listValue([objectValue([
                ValueField("contribution", textValue("run")), ValueField("field", textValue("code")), ValueField("max_bytes", integerValue(262144))])])) }
            document.put("plugins", listValue(entries.toArray()))
            File.writeTo(directory + "/settings/plugins/services.json", stringifyUnifiedJson(document).toArray())
            let connection = SqliteDatabase(directory + "/state/state.db"); db = Some(connection)
            root = directory; product = opened; record = installed; workspace = resources; database = connection
        } catch (error: Exception) {
            match (db) { case Some(value) => value.close(); case None => () }
            let _ = opened.close(); remove(directory, recursive: true); throw error
        }
    }
    prop name: String { get() { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".run" } }
    func input(code!: String = "return await tools.read({\"path\":\"first.txt\"});"): AgentValue {
        objectValue([ValueField("code", textValue(code))])
    }
    func direct(thread: String, args: AgentValue, budget: ExecutionBudget): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.ExtensionInvoke)]), ToolCall("program-call", name, args), budget: budget)
    }
    func completed(value: Result<ToolInvocationResult>): ToolResult {
        match (value) { case Result.Ok(ToolInvocationResult.Completed(result)) => result
            case Result.Err(error) => throw IllegalStateException(error.describe()); case _ => throw IllegalStateException("Program did not complete") }
    }
    func count(thread: String, sql: String): Int64 {
        Int64.parse(database.query(sql, [SqlParameter.Text(thread)])[0].required(0))
    }
    func children(thread: String): Int64 {
        count(thread, "SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=?")
    }
    func close(): Unit { database.close(); product.close().value().getOrThrow(); remove(root, recursive: true) }
}

@Test
class PluginProgramDelegationTests {
    @TestCase
    func actualInstalledProgramWorkspaceAndReadviewShareOneDirectRootAndOneSlot(): Unit {
        let f = ProgramDelegationFixture()
        try {
            let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
            let result = f.completed(f.direct("program-direct", f.input(), budget))
            @Expect(!result.isError); @Expect(httpIntentText(result.output, "status"), "completed")
            @Expect(httpIntentText(result.output.field("value").getOrThrow(), "content"), "[first.txt#F27C]\n1:before\n2:")
            @Expect(budget.snapshot().toolCalls, 3); @Expect(budget.snapshot().activeTools, 0)
            @Expect(f.children("program-direct"), 2)
            let rows = f.database.query("SELECT a.operation_id,a.parent_operation_id,a.root_operation_id,a.depth,a.child_call_id,o.run_id,p.outcome " +
                "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id " +
                "JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id='program-direct' ORDER BY a.depth")
            @Expect(rows.size, 2); @Expect(rows[0].required(3), "1"); @Expect(rows[1].required(3), "2")
            @Expect(rows[1].required(1), rows[0].required(0)); @Expect(rows[1].required(2), rows[0].required(2))
            @Expect(rows[1].required(4) != rows[0].required(4))
            for (row in rows) {
                @Expect(row.required(6), "completed")
                @Expect(DurableOperationStore(f.database).loadCall(OperationId(row.required(0)), RunId(row.required(5))).value().getOrThrow().callId, row.required(4))
            }
            @Expect(f.count("program-direct", "SELECT COUNT(*) FROM items WHERE thread_id=? AND kind='tool_call'"), 1)
            @Expect(f.count("program-direct", "SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=?"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualCommittedProgramUsesTheFrozenCatalogAndTwoSerialReadBranches(): Unit {
        let f = ProgramDelegationFixture()
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("program-committed")))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("program-committed", f.name,
                f.input(code: "const a = await tools.read({\"path\":\"first.txt\"}); const b = await tools.read({\"path\":\"first.txt\"}); return b;"))
            @Expect(session.submit("Run the installed readonly composition.").isOk()); @Expect(session.approval().isNone())
            @Expect(f.children("program-committed"), 4)
            @Expect(f.count("program-committed", "SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=?"), 1)
            @Expect(f.count("program-committed", "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"), 5)
            @Expect(f.database.scalarInt("SELECT COUNT(DISTINCT root_operation_id) FROM derived_operation_admissions"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('executing','prepared','recovery_required')"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualWriteModeApprovalRejectCancelAndConfigRevocationNeverDispatchAChild(): Unit {
        for (mode in ["reject", "cancel", "revoke", "approve"]) {
            let f = ProgramDelegationFixture(mode: ApprovalMode.Write)
            try {
                let thread = "program-approval-" + mode
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, f.name, f.input())
                @Expect(session.submit("Review this exact readonly delegation.").isOk())
                let pending = session.approval().getOrThrow(); @Expect(pending.toolName, f.name)
                @Expect(f.children(thread), 0)
                if (mode == "cancel") { @Expect(session.cancel().isOk()) }
                else {
                    if (mode == "revoke") {
                        let path = f.root + "/settings/plugins/services.json"
                        let changed = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
                        changed.field("plugins").getOrThrow().items[1].put("tool_delegations", listValue([]))
                        File.writeTo(path, stringifyUnifiedJson(changed).toArray())
                    }
                    let outcome = session.decide(pending.operationId.value, if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve })
                    if (mode != "revoke") { @Expect(outcome.isOk()) }
                }
                @Expect(f.children(thread), if (mode == "approve") { 2 } else { 0 })
                @Expect(String.fromUtf8(File.readFrom(f.root + "/workspace/first.txt")), "before\n")
            } finally { f.close() }
        }
    }

    @TestCase
    func actualReadviewProcessOutputFailureCannotPublishProgramSuccess(): Unit {
        let f = ProgramDelegationFixture()
        try {
            File.writeTo(f.root + "/workspace/first.txt", Array<Byte>(40000, repeat: 65))
            let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1,
                processLimits: ExecutionResourceLimits(maxOutputBytes: 16384))
            let result = f.direct("program-output-failure", f.input(), budget)
            @Expect(f.completed(result).isError)
            @Expect(f.children("program-output-failure"), 2)
            @Expect(f.count("program-output-failure", "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='failed'"), 3)
            @Expect(f.count("program-output-failure", "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"), 0)
            @Expect(budget.snapshot().activeTools, 0)
            @Expect(File.readFrom(f.root + "/workspace/first.txt").size, 40000)
        } finally { f.close() }
    }

    @TestCase
    func readonlyGrantCannotDelegateWritesOutsidePathsUnknownAliasesOrExhaustedBudgets(): Unit {
        let wrong = ProgramDelegationFixture(target: "edit")
        try {
            let denied = wrong.direct("program-wrong-target", wrong.input(), ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            @Expect(match (denied) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case Result.Ok(ToolInvocationResult.Denied(_)) => true; case _ => false })
            @Expect(wrong.children("program-wrong-target"), 0)
        } finally { wrong.close() }
        let f = ProgramDelegationFixture()
        try {
            for ((thread, code, calls) in [("program-outside", "return await tools.read({\"path\":\"../outside.txt\"});", 3),
                ("program-alias", "return await tools.write({\"path\":\"new.txt\",\"content\":\"bad\"});", 3),
                ("program-budget", "return await tools.read({\"path\":\"first.txt\"});", 2)]) {
                let denied = f.direct(thread, f.input(code: code), ExecutionBudget(maxToolCalls: calls, maxConcurrentTools: 1))
                @Expect(match (denied) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case Result.Ok(ToolInvocationResult.Denied(_)) => true; case _ => false })
                @Expect(f.count(thread, "SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND e.tool_id='host.process.readview' AND p.outcome='completed'"), 0)
            }
            @Expect(!exists(Path(f.root + "/workspace/new.txt")))
            @Expect(String.fromUtf8(File.readFrom(f.root + "/outside.txt")), "private outside\n")
            match (f.product.setPluginEnabled(productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace)), false, PluginInstallScope.Workspace)) {
                case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            let stale = f.direct("program-stale", f.input(), ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            @Expect(match (stale) { case Result.Err(_) => true; case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case Result.Ok(ToolInvocationResult.Denied(_)) => true; case _ => false })
            @Expect(f.children("program-stale"), 0)
        } finally { f.close() }
    }
}
