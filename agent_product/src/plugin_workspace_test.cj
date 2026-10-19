package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.env.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func workspacePluginOpen(root: String, mode: ApprovalMode): ProductRuntime {
    openProduct(config: ProductConfig(workspaceRoot: root + "/workspace", settingsRoot: root + "/settings",
        stateRoot: root + "/state", fixture: true, asyncEnabled: false, approvalMode: mode)).value().getOrThrow()
}
func workspacePluginInstall(product: ProductRuntime, root: String): ProductPluginRecord {
    let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKSPACE_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    workspaceReadViewConfigure(root, record, ["read", "grep", "glob"])
    match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(_) => ()
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    for (name in ["bash", "bash_readonly"]) { let _ = product.unregisterTool(name) }
    for (definition in product.tools()) {
        if (["read", "grep", "glob", "edit", "write", "bash", "bash_readonly"].contains(definition.name)) {
            throw IllegalStateException("Workspace tools must be genuinely absent from the default catalog")
        }
    }
    record
}
func workspacePluginCall(product: ProductRuntime, record: ProductPluginRecord, thread: String,
    localName: String, arguments: AgentValue, budget: ExecutionBudget): ToolResult {
    match (product.vnext.executeCanonicalTool(SessionId(thread), CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
        Capability(CapabilityKind.WorkspaceRead)]), ToolCall(thread, "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "." + localName,
        arguments), budget: budget)) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("workspace package call did not complete")
    }
}
func workspacePluginPlan(product: ProductRuntime, record: ProductPluginRecord, thread: String, patch: String): AgentValue {
    let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
    let result = workspacePluginCall(product, record, thread, "edit", objectValue([ValueField("input", textValue(patch))]), budget)
    if (result.isError || result.output.field("applied").getOrThrow().asBool() || budget.snapshot().toolCalls != 3 || budget.snapshot().activeTools != 0) {
        throw IllegalStateException("hashline package must propose through two serial durable children")
    }
    result.output.field("application_plan").getOrThrow()
}
func workspacePlanArgs(plan: AgentValue): AgentValue {
    objectValue([ValueField("plan_ref", plan.field("plan_ref").getOrThrow()), ValueField("plan_digest", plan.field("plan_digest").getOrThrow())])
}
func workspacePlanSession(product: ProductRuntime, thread: String, plan: AgentValue): ApplicationSession {
    let session = product.applicationSession(sessionId: Some(SessionId(thread)))
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, "apply_file_plan", workspacePlanArgs(plan))
    let submitted = session.submit("Review the exact immutable workspace change plan.").value().getOrThrow()
    let pending = session.approval().getOrThrow()
    if (submitted.approval.isNone() || pending.toolName != "apply_file_plan" || pending.sessionApprovalAllowed ||
        pending.capability.kind != CapabilityKind.WorkspaceWrite ||
        pending.preview.field("plan_digest").getOrThrow().text != plan.field("plan_digest").getOrThrow().text) {
        throw IllegalStateException("workspace apply must use the existing exact one-time approval")
    }
    session
}

@Test
class PluginWorkspaceTests {
    @TestCase
    func actualReadSearchAndGlobHaveDirectAndCommittedReceiptsWithoutStaticTools(): Unit {
        let root = pluginContractTemp("workspace-package-read")
        Directory.create(root + "/workspace", recursive: true)
        File.writeTo(root + "/workspace/first.txt", "before\n".toArray())
        File.writeTo(root + "/workspace/second.txt", "alpha\nbeta\n".toArray())
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let read = workspacePluginCall(product, record, "workspace-read", "read", objectValue([
                ValueField("path", textValue("first.txt"))]), ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!read.isError); @Expect(read.output.field("content").getOrThrow().text, "[first.txt#F27C]\n1:before\n2:")
            let glob = workspacePluginCall(product, record, "workspace-glob", "glob", objectValue([
                ValueField("pattern", textValue("*.txt"))]), ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(!glob.isError); @Expect(glob.output.field("count").getOrThrow().asNumberText(), "2")
            let session = product.applicationSession(sessionId: Some(SessionId("workspace-model-search")))
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("workspace-model-search", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".grep",
                objectValue([ValueField("pattern", textValue("BEF.RE")), ValueField("path", textValue("first.txt;second.txt"))]))
            @Expect(session.submit("Search these workspace files.").isOk()); @Expect(session.approval().isNone())
            let rows = database.query("SELECT e.normalized_plan,receipt.outcome FROM operation_effect_records e " +
                "JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
                "WHERE r.thread_id='workspace-model-search' AND e.tool_id='host.process.readview'")
            @Expect(rows.size, 1); @Expect(rows[0].required(1), "completed")
            let operations = database.query("SELECT o.id,o.run_id FROM operations o JOIN runs r ON r.id=o.run_id " +
                "WHERE r.thread_id='workspace-read' AND EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)")
            @Expect(operations.size, 1)
            let child = DurableOperationStore(database).loadPlan(OperationId(operations[0].required(0)), RunId(operations[0].required(1))).value().getOrThrow()
            @Expect(child.effectClass, OperationEffectClass.ReadOnly); @Expect(child.networkPolicy.mode, NetworkPolicyMode.Denied)
            @Expect(child.requiredCapabilities.size, 1); @Expect(child.requiredCapabilities[0].kind, CapabilityKind.WorkspaceRead)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-read'"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations o ON o.id=d.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-model-search'") > 0)
            let denied = product.vnext.executeCanonicalTool(SessionId("workspace-no-read"), CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]),
                ToolCall("workspace-no-read", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".read", objectValue([ValueField("path", textValue("first.txt"))])))
            // Canonicalization failed before any tool operation was admitted.
            // The actual gateway settles its Run and returns the stable error ToolResult.
            let denial = match (denied) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => value
                case _ => throw IllegalStateException("missing read must return its actual recoverable preparation failure")
            }
            try {
                @Expect(denial.isError)
                @Expect(denial.output.field("error").getOrThrow().text, "read_view.capability_denied")
                @Expect(denial.receiptId, "")
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='workspace-no-read' AND state='failed'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-no-read'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-no-read'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-no-read'"), 0)
            } finally { denial.releasePayload() }
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/first.txt")), "before\n")
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func multifileHashlinePlanPersistsAcrossRestartAndUsesExactApprovalAndAtomicCas(): Unit {
        let root = pluginContractTemp("workspace-package-edit")
        Directory.create(root + "/workspace", recursive: true)
        for (path in ["first.txt", "second.txt"]) { File.writeTo(root + "/workspace/" + path, "before\n".toArray()) }
        var product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let patch = "[first.txt#F27C]\nSWAP 1:\n+first after\n[second.txt#F27C]\nSWAP 1:\n+second after"
            let plan = workspacePluginPlan(product, record, "workspace-edit-preview", patch)
            let fresh = workspacePluginPlan(product, record, "workspace-edit-fresh", patch)
            let artifact = ProductArtifactStore(root + "/state", database: Some(database)).read(plan.field("plan_ref").getOrThrow().text, limit: 1048576).value().getOrThrow()
            let stored = parseUnifiedJson(artifact.content); let source = stored.field("source").getOrThrow()
            @Expect(stored.field("schema").getOrThrow().text, "axyndra.file-application-plan/v2")
            @Expect(source.field("kind").getOrThrow().text, "plugin")
            @Expect(source.field("plugin_namespace").getOrThrow().text, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(source.field("package_digest").getOrThrow().text, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))
            @Expect(source.field("contribution").getOrThrow().text, "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".edit")
            @Expect(source.field("program_id").isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id " +
                "JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id='workspace-edit-preview' AND p.outcome='completed'"), 2)
            for (path in ["first.txt", "second.txt"]) { @Expect(String.fromUtf8(File.readFrom(root + "/workspace/" + path)), "before\n") }
            product.close(); product = workspacePluginOpen(root, ApprovalMode.AlwaysAsk)
            let reject = workspacePlanSession(product, "workspace-apply-reject", plan)
            @Expect(reject.decide(reject.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            let cancel = workspacePlanSession(product, "workspace-apply-cancel", plan)
            @Expect(cancel.cancel().isOk())
            let conflict = workspacePlanSession(product, "workspace-apply-conflict", plan)
            File.writeTo(root + "/workspace/second.txt", "concurrent change\n".toArray())
            @Expect(conflict.decide(conflict.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isError())
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/first.txt")), "before\n")
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/second.txt")), "concurrent change\n")
            File.writeTo(root + "/workspace/second.txt", "before\n".toArray())
            let apply = workspacePlanSession(product, "workspace-apply-success", fresh)
            @Expect(apply.decide(apply.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/first.txt")), "first after\n")
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/second.txt")), "second after\n")
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func staleAnchorsSymlinksAndDisabledPackageCannotCreateWriteEffects(): Unit {
        let root = pluginContractTemp("workspace-package-rejection")
        Directory.create(root + "/workspace", recursive: true)
        File.writeTo(root + "/workspace/first.txt", "before\n".toArray())
        File.writeTo(root + "/outside.txt", "outside\n".toArray())
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            let stale = workspacePluginCall(product, record, "workspace-stale", "edit", objectValue([
                ValueField("input", textValue("[first.txt#0000]\nSWAP 1:\n+after"))]), ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            @Expect(stale.isError); @Expect(stale.output.field("error").getOrThrow().text, "edit.stale_anchor")
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id " +
                "JOIN runs r ON r.id=o.run_id WHERE r.thread_id='workspace-stale' AND e.tool_id='host.file.plan.propose'"), 0)
            SymbolicLink.create(root + "/workspace/escape.txt", to: root + "/outside.txt")
            let escaped = workspacePluginCall(product, record, "workspace-escape", "read", objectValue([
                ValueField("path", textValue("escape.txt"))]), ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(escaped.isError); @Expect(escaped.output.field("error").getOrThrow().text, "read_view.resource_invalid")
            let proposed = workspacePluginCall(product, record, "workspace-create-preview", "write", objectValue([
                ValueField("path", textValue("new.txt")), ValueField("content", textValue("new content"))]), ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            @Expect(!proposed.isError); @Expect(!exists(Path(root + "/workspace/new.txt")))
            let noWrite = product.vnext.executeCanonicalTool(SessionId("workspace-no-write"), CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("workspace-no-write", "apply_file_plan", workspacePlanArgs(proposed.output.field("application_plan").getOrThrow())))
            @Expect(match (noWrite) { case Result.Ok(ToolInvocationResult.Denied(_)) => true; case Result.Err(_) => true; case _ => false })
            let _ = product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false, PluginInstallScope.Workspace)
            let disabled = product.invokeLocalTool(SessionId("workspace-disabled"), "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".write",
                objectValue([ValueField("path", textValue("new.txt")), ValueField("content", textValue("forbidden"))]))
            @Expect(disabled.isError()); @Expect(!exists(Path(root + "/workspace/new.txt")))
            @Expect(String.fromUtf8(File.readFrom(root + "/workspace/first.txt")), "before\n")
            @Expect(String.fromUtf8(File.readFrom(root + "/outside.txt")), "outside\n")
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }
}

func workspaceReadViewConfigure(root: String, record: ProductPluginRecord, names: Array<String>, parameterReferences!: Array<String> = []): Unit {
    let grants = ArrayList<AgentValue>()
    for (name in names) {
        grants.add(objectValue([ValueField("kind", textValue("tool")), ValueField("name", textValue(name)),
            ValueField("effect", textValue("read_only")), ValueField("services", listValue([textValue("process.readview")]))]))
    }
    let document = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
        objectValue([ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
            ValueField("configuration", objectValue([])), ValueField("requests", listValue([])), ValueField("credentials", listValue([])),
            ValueField("tool_read_grants", listValue(grants.toArray()))])]))])
    if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
    let configured = if (parameterReferences.size == 0) { document } else {
        let fields = ArrayList<ValueField>(document.field("plugins").getOrThrow().items[0].fields)
        fields.add(ValueField("read_view_parameter_references", listValue(parameterReferences.map { name => textValue(name) })))
        objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue(fields.toArray())]))])
    }
    File.writeTo(root + "/settings/plugins/services.json", stringifyUnifiedJson(configured).toArray())
}
