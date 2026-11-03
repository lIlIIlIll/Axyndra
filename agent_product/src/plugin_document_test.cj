package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import process4cj as document_process
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func documentFixtureConfigure(root: String, record: ProductPluginRecord, write: Bool): Unit {
    if (!exists(Path(root + "/settings/plugins"))) {
        Directory.create(root + "/settings/plugins", recursive: true)
    }
    let right = objectValue([ValueField("key", textValue("todo")), ValueField("read", boolValue(true)), ValueField("write", boolValue(write))])
    let tool = objectValue([ValueField("name", textValue("update")), ValueField("documents", listValue([right]))])
    let plugin = objectValue([ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))), ValueField("tools", listValue([tool]))])
    let configuration = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([plugin]))])
    File.writeTo(root + "/settings/plugins/documents.json", stringifyUnifiedJson(configuration).toArray())
}

func documentFixtureInstall(product: ProductRuntime, root: String): ProductPluginRecord {
    let source = root + "/document-plugin"
    Directory.create(source)
    File.writeTo(source + "/main.py", File.readFrom(getVariable("AXYNDRA_DOCUMENT_PLUGIN_FIXTURE").getOrThrow()))
    let mode = document_process.runProcess(document_process.ProcessCommand("/usr/bin/chmod", arguments: ["700", source + "/main.py"], maxOutputBytes: 4096))
    if (mode.status.code != 0) { throw IllegalStateException("cannot set native fixture executable mode") }
    File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
        ValueField("id", textValue("document-fixture")), ValueField("version", textValue("1.0.0")),
        ValueField("entry_kind", textValue("native-executable")), ValueField("entrypoint", textValue("main.py")),
        ValueField("sdk_range", textValue("[2.1.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
        ValueField("capabilities", listValue([textValue("document.store")])), ValueField("contributions", listValue([
            objectValue([ValueField("kind", textValue("tool")), ValueField("name", textValue("update"))])]))])).toArray())
    let record = match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(value) => value; case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message)) }
    documentFixtureConfigure(root, record, true)
    match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message)) }
    record
}

func documentFixtureArguments(mode!: String = ""): AgentValue {
    objectValue([ValueField("next", objectValue([ValueField("count", integerValue(1))])), ValueField("mode", textValue(mode))])
}

@Test
class PluginDocumentServiceTests {
    @TestCase
    func actualNativeDirectAndCommittedReadThenCasUseOneRunAndThreeCanonicalReceipts(): Unit {
        let root = pluginContractTemp("document-actual")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = documentFixtureInstall(product, root)
            let name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update"
            let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
            let direct = product.vnext.executeCanonicalTool(SessionId("doc-direct"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("doc-direct", name, documentFixtureArguments()), budget: budget)
            @Expect(match (direct) { case Result.Ok(ToolInvocationResult.Completed(value)) => !value.isError; case _ => false })
            @Expect(budget.snapshot().activeTools, 0); @Expect(budget.snapshot().toolCalls, 3)
            let session = product.applicationSession(sessionId: Some(SessionId("doc-committed")))
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("doc-committed", name, documentFixtureArguments())
            @Expect(session.submit("Perform the exact native document update.").isOk()); @Expect(session.approval().isNone())
            for (thread in ["doc-direct", "doc-committed"]) {
                let snapshot = SqlitePluginDocumentRepository(database).read(ThreadId(thread), LaneId("main"), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "todo").value().getOrThrow()
                @Expect(snapshot.revision, 1); @Expect(snapshot.encoded, "{\"count\":1}")
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id=" + sqliteText(thread)), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operations o ON o.id=receipt.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=" + sqliteText(thread) + " AND receipt.outcome='completed'"), 3)
            }
            @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'"), 2)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 2)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func readApprovalNeverApprovesCasAndConfigReplacementRejectsTheFrozenParent(): Unit {
        let root = pluginContractTemp("document-approval")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = documentFixtureInstall(product, root)
            let session = product.applicationSession(sessionId: Some(SessionId("doc-approve")))
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("doc-approve", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments())
            @Expect(session.submit("Review the document update.").isOk())
            let read = session.approval().getOrThrow()
            @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = session.approval().getOrThrow()
            @Expect(mutation.operationId.value != read.operationId.value)
            @Expect(mutation.toolName, "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update")
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            documentFixtureConfigure(root, record, false)
            let result = session.decide(mutation.operationId.value, ApprovalDecision.Approve)
            @Expect(result.isError() || session.approval().isNone())
            @Expect(SqlitePluginDocumentRepository(database).read(ThreadId("doc-approve"), LaneId("main"), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "todo").value().getOrThrow().revision, 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func disableReenableAfterActualReadCannotReuseTheApprovedOldGeneration(): Unit {
        let root = pluginContractTemp("document-aba")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = documentFixtureInstall(product, root)
            let session = product.applicationSession(sessionId: Some(SessionId("doc-aba")))
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("doc-aba", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update", documentFixtureArguments())
            @Expect(session.submit("Review this installed document update.").isOk())
            let read = session.approval().getOrThrow()
            @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = session.approval().getOrThrow()
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            for (enabled in [false, true]) {
                @Expect(match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), enabled, PluginInstallScope.Workspace)) {
                    case PluginRegistryResult.Ok(_) => true; case PluginRegistryResult.Err(_) => false })
            }
            let decided = session.decide(mutation.operationId.value, ApprovalDecision.Approve)
            @Expect(decided.isError() || session.approval().isNone())
            @Expect(session.approval().isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func namespaceCeilingAndAClaimedSuccessWithoutTheFrozenReceiptCannotWrite(): Unit {
        let root = pluginContractTemp("document-refusals")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = documentFixtureInstall(product, root)
            let name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".update"
            let denied = product.vnext.executeCanonicalTool(SessionId("doc-denied"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:other")]),
                ToolCall("doc-denied", name, documentFixtureArguments()))
            @Expect(match (denied) { case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'"), 0)
            let skipped = product.vnext.executeCanonicalTool(SessionId("doc-skipped"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("doc-skipped", name, documentFixtureArguments(mode: "skip")), budget: ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            @Expect(skipped.isError())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }
}
