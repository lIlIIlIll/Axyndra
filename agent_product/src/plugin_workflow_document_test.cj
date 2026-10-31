package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import process4cj as workflow_test_process
import std.env.*
import std.convert.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class WorkflowDocumentFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ProductPluginRecord
    let tool: String
    init(mode!: ApprovalMode = ApprovalMode.Yolo, provider!: String = "", payload!: Bool = false) {
        let root = pluginContractTemp("installed-workflow-document")
        Directory.create(root + "/workspace", recursive: true)
        let product = workspacePluginOpen(root, mode)
        let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
        if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
        let right = objectValue([ValueField("key", textValue("todo")), ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])
        let tool = objectValue([ValueField("name", textValue("todo")), ValueField("documents", listValue([right]))])
        let goalTool = objectValue([ValueField("name", textValue("goal")), ValueField("documents", listValue([
            objectValue([ValueField("key", textValue("goal")), ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])]))])
        for (selected in [tool, goalTool]) {
            if (provider != "") { selected.put("preparation_provider", textValue(provider)) }
            if (payload) {
                selected.put("payload_references", boolValue(true))
                selected.put("tool_payload_limits", OrdinaryToolPayloadLimits(httpIntentText(selected, "name")).value())
            }
        }
        File.writeTo(root + "/settings/plugins/documents.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("tools", listValue([tool, goalTool]))])]))])).toArray())
        match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
            case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
        this.root = root; this.product = product; this.record = record
        this.database = SqliteDatabase(root + "/state/state.db")
        this.tool = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".todo"
    }
    func call(thread: String, args: AgentValue, localName!: String = "todo"): ToolResult {
        let result = product.vnext.executeCanonicalTool(SessionId(thread),
            CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
            ToolCall(thread + "-call", "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "." + localName, args), budget: ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
        match (result) { case Result.Ok(ToolInvocationResult.Completed(value)) => value
            case Result.Err(error) => throw IllegalStateException(error.describe())
            case _ => throw IllegalStateException("installed document Tool did not complete") }
    }
    func snapshot(thread: String, key!: String = "todo"): PluginDocumentSnapshot {
        lifecycleTestRequire(SqlitePluginDocumentRepository(database).read(ThreadId(thread), LaneId("main"), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), key))
    }
    func close(): Unit { database.close(); let _ = product.close(); remove(root, recursive: true) }
}

@Test
class InstalledWorkflowDocumentTests {
    @TestCase
    func actualSetCreatesThenReplacesOnlyAfterCanonicalGoalRead(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("goal-set-user")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "goal" }
            @Expect(routes.size, 1)
            let messages = ArrayList<String>()
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "set \"first objective 雪\"", { _, text => messages.add(text) }).isOk())
            let first = f.snapshot("goal-set-user", key: "goal")
            @Expect(httpIntentText(lifecycleTestRequire(first.decode()), "objective"), "first objective 雪")
            let original = workflowDocumentTestAllowance(f, "goal-set-user").getOrThrow()
            @Expect(original.enabled); @Expect(!original.closed)
            @Expect(messages[0].startsWith("Goal mode enabled.\nObjective: first objective 雪"))
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "budget 100", { _, text => messages.add(text) }).isOk())
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "set replace the objective", { _, text => messages.add(text) }).isOk())
            let after = lifecycleTestRequire(f.snapshot("goal-set-user", key: "goal").decode())
            @Expect(httpIntentText(after, "objective"), "replace the objective")
            @Expect(after.field("tokenBudget").getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(workflowDocumentTestAllowance(f, "goal-set-user").getOrThrow().generation, original.generation + 2)
            @Expect(messages[2].startsWith("Goal replaced.\nObjective: replace the objective"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE goal_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualPausedSetPreservesItsDocumentAndCannotCreateNewContinuationControl(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("goal-set-paused")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "goal" }
            @Expect(routes.size, 1)
            let messages = ArrayList<String>()
            for (text in ["set keep this objective", "pause"]) {
                @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, text, { _, value => messages.add(value) }).isOk()) }
            let paused = workflowDocumentTestAllowance(f, "goal-set-paused").getOrThrow()
            @Expect(!paused.enabled)
            let prior = f.snapshot("goal-set-paused", key: "goal")
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "set must not replace", { _, value => messages.add(value) }).isOk())
            @Expect(messages[2], "Resume the current goal first, or drop it before setting a new objective.")
            @Expect(f.snapshot("goal-set-paused", key: "goal").encoded, prior.encoded)
            @Expect(f.snapshot("goal-set-paused", key: "goal").revision, prior.revision)
            @Expect(workflowDocumentTestAllowance(f, "goal-set-paused").getOrThrow().eventId, paused.eventId)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualDeferredGoalControlIsReviewedOnlyAfterItsReadAndRejectedWithoutAllowance(): Unit {
        let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk, provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("goal-set-reviewed")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "goal" }
            @Expect(routes.size, 1)
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "set decide only after reading", { _, _ => () }).isOk())
            let read = session.approval().getOrThrow(); @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(read.preview.field("host_user_control").isNone())
            @Expect(workflowDocumentTestAllowance(f, "goal-set-reviewed").isNone())
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = session.approval().getOrThrow()
            @Expect(mutation.toolName, "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal")
            let control = mutation.preview.field("host_user_control").getOrThrow()
            @Expect(httpIntentText(control, "action"), "create")
            @Expect(httpIntentText(control, "next_prompt"), "decide only after reading")
            @Expect(control.field("token_budget").getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(session.decide(mutation.operationId.value, ApprovalDecision.Reject).isError())
            @Expect(session.approval().isNone())
            @Expect(workflowDocumentTestAllowance(f, "goal-set-reviewed").isNone())
            @Expect(f.snapshot("goal-set-reviewed", key: "goal").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }

    @TestCase
    func plainCanonicalToolCannotTurnGoalCommandBytesIntoUserControl(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let result = f.product.vnext.executeCanonicalTool(SessionId("goal-no-command-owner"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("goal-no-command-owner", "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal",
                    objectValue([ValueField("command_args", textValue("set forged user continuation"))])))
            @Expect(match (result) { case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => try { value.isError } finally { value.releasePayload() }
                case _ => false })
            @Expect(workflowDocumentTestAllowance(f, "goal-no-command-owner").isNone())
            @Expect(f.snapshot("goal-no-command-owner", key: "goal").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        } finally { f.close() }
    }

    @TestCase
    func installedTodoHelpIsOnlyAnActualCommandMessage(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("slash-help")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "todo" }
            @Expect(routes.size, 1)
            let messages = ArrayList<String>()
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "help", { _, text => messages.add(text) }).isOk())
            @Expect(messages.size, 1); @Expect(messages[0].contains("/todo append"))
            @Expect(session.approval().isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.snapshot("slash-help").revision, 0)
        } finally { f.close() }
    }

    @TestCase
    func installedQuotedSlashKeepsReadAndMutationApprovalInOneActualRun(): Unit {
        let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk, provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("slash-two-approvals")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "todo" }
            @Expect(routes.size, 1)
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "append \"release phase\" \"ship 雪 now\"", { _, _ => () }).isOk())
            let read = session.approval().getOrThrow(); @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.snapshot("slash-two-approvals").revision, 0)
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = session.approval().getOrThrow(); @Expect(mutation.toolName, f.tool)
            @Expect(mutation.operationId.value != read.operationId.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.snapshot("slash-two-approvals").revision, 0)
            let completed = lifecycleTestRequire(session.decide(mutation.operationId.value, ApprovalDecision.Approve))
            @Expect(completed.text, "Appended to Release Phase: Ship 雪 now")
            @Expect(session.approval().isNone())
            let saved = f.snapshot("slash-two-approvals")
            @Expect(saved.revision, 1)
            let phase = lifecycleTestRequire(saved.decode()).items[0]
            @Expect(httpIntentText(phase, "name"), "Release Phase")
            @Expect(httpIntentText(phase.field("tasks").getOrThrow().items[0], "content"), "Ship 雪 now")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE todo_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualSlashProgressReadCopyAndClearPreserveCanonicalDocumentHistory(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("slash-progress")))
            let routes = session.javascriptPluginCommands().filter { value => value.extensionId == productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) && value.name == "todo" }
            @Expect(routes.size, 1)
            let messages = ArrayList<String>()
            for (raw in ["append \"first task\"", "append \"second task\"", "done first"]) {
                @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, raw, { _, text => messages.add(text) }).isOk())
                @Expect(session.approval().isNone())
            }
            @Expect(messages[2], "Marked completed: First task")
            let prior = f.snapshot("slash-progress")
            let tasks = lifecycleTestRequire(prior.decode()).items[0].field("tasks").getOrThrow().items
            @Expect(httpIntentText(tasks[0], "status"), "completed")
            @Expect(httpIntentText(tasks[1], "status"), "in_progress")
            for (raw in ["", "copy"]) {
                @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, raw, { _, text => messages.add(text) }).isOk())
                @Expect(f.snapshot("slash-progress").revision, prior.revision)
                @Expect(f.snapshot("slash-progress").encoded, prior.encoded)
            }
            @Expect(messages[3], "# Todos\n- [x] First task\n- [/] Second task")
            @Expect(messages[4], "Copy not available in non-interactive mode; printing instead:\n\n" + messages[3])
            @Expect(session.invokeJavaScriptPluginCommand(routes[0].routeName, "rm", { _, text => messages.add(text) }).isOk())
            @Expect(messages[5], "Cleared all todos.")
            @Expect(lifecycleTestRequire(f.snapshot("slash-progress").decode()).items.isEmpty())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 18)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE todo_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func invalidSlashUsageCompletesOnlyReadWithoutChangingTheDocument(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let result = f.call("slash-invalid", objectValue([ValueField("command_args", textValue("copy extra"))]))
            try {
                @Expect(result.isError)
                let error = result.output.field("error").getOrThrow()
                @Expect(httpIntentText(error, "code"), "application.invalid_command_arguments")
                @Expect(httpIntentText(error, "message"), "invalid command arguments")
                @Expect(httpIntentText(error.field("fields").getOrThrow(), "usage"), "/todo copy")
            } finally { result.releasePayload() }
            @Expect(f.snapshot("slash-invalid").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE todo_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func samePackageProfileSourcesRemainIndependentForDocumentAndOrdinaryTools(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let path = f.root + "/settings/plugins/services.json"
            let ordinary = OrdinaryToolPayloadLimits("goal", maxInputBytes: 2000000)
            File.writeTo(path, stringifyUnifiedJson(objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
                objectValue([ValueField("namespace", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                    ValueField("package_digest", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))), ValueField("configuration", objectValue([])),
                    ValueField("credentials", listValue([])), ValueField("requests", listValue([])),
                    ValueField("tool_payload_limits", listValue([ordinary.value()]))])]))])).toArray())
            let settings = f.root + "/settings"
            let available = ["todo", "goal"]
            let document = Some(OrdinaryToolPayloadLimits("goal"))
            let docSelected = lifecycleTestRequire(productOrdinaryToolPayloadSelection(settings, f.record.descriptor,
                available, "tool", "goal", document, document: true))
            let regular = lifecycleTestRequire(productOrdinaryToolPayloadSelection(settings, f.record.descriptor,
                available, "tool", "goal", Some(ordinary)))
            @Expect(docSelected != regular)
            @Expect(productOrdinaryToolPayloadSelection(settings, f.record.descriptor, available, "tool", "goal", document).isError())
            @Expect(productOrdinaryToolPayloadSelection(settings, f.record.descriptor, available, "tool", "goal", Some(ordinary), document: true).isError())
            File.writeTo(f.root + "/settings/plugins/documents.json", "invalid operator document grants".toArray())
            @Expect(productOrdinaryToolPayloadSelection(settings, f.record.descriptor, available, "tool", "goal", document, document: true).isError())
            @Expect(lifecycleTestRequire(productOrdinaryToolPayloadSelection(settings, f.record.descriptor,
                available, "tool", "goal", Some(ordinary))), regular)
        } finally { f.close() }
    }
    @TestCase
    func actualSelectedProviderAndProfilePreserveNinetySixKiBDocumentAndResult(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            let text = String.fromUtf8(Array<Byte>(98304, repeat: 97)) + "-雪-end"
            let initialized = f.call("workflow-large", objectValue([ValueField("op", textValue("init")),
                ValueField("items", listValue([textValue(text)]))]))
            try {
                @Expect(!initialized.isError)
                @Expect(httpIntentText(initialized.output.field("phases").getOrThrow().items[0].field("tasks").getOrThrow().items[0], "content"), text)
            } finally { initialized.releasePayload() }
            let saved = f.snapshot("workflow-large")
            @Expect(saved.encoded.size > 98304); @Expect(saved.revision, 1)
            let viewed = f.call("workflow-large", objectValue([ValueField("op", textValue("view"))]))
            try {
                @Expect(!viewed.isError)
                @Expect(httpIntentText(viewed.output.field("phases").getOrThrow().items[0].field("tasks").getOrThrow().items[0], "content"), text)
            } finally { viewed.releasePayload() }
            @Expect(f.snapshot("workflow-large").encoded, saved.encoded)
            @Expect(f.snapshot("workflow-large").revision, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE todo_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func exactProviderSelectionCannotFallBackToToolOrAnotherContribution(): Unit {
        for (provider in ["todo", "absent", "propose"]) {
            let f = WorkflowDocumentFixture(provider: provider, payload: true)
            try {
                let outcome = f.product.vnext.executeCanonicalTool(SessionId("bad-provider"),
                    CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                    ToolCall("bad-provider", f.tool, objectValue([ValueField("op", textValue("init")), ValueField("items", listValue([textValue("no mutation")]))])))
                @Expect(match (outcome) { case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
                    case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
                @Expect(f.snapshot("bad-provider").revision, 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func operatorProviderChangeCannotExecuteThePreviouslyApprovedDocument(): Unit {
        let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk, provider: "prepare_document", payload: true)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("provider-approval-change")))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("provider-approval-change", f.tool,
                objectValue([ValueField("op", textValue("init")), ValueField("items", listValue([textValue("frozen")]))]))
            @Expect(session.submit("Create the reviewed document.").isOk())
            let read = session.approval().getOrThrow(); @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let parent = session.approval().getOrThrow(); @Expect(parent.toolName, f.tool)
            let path = f.root + "/settings/plugins/documents.json"
            let data = parseUnifiedJson(String.fromUtf8(File.readFrom(path)), maxBytes: 65536)
            data.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items[0].put("preparation_provider", textValue("propose"))
            File.writeTo(path, stringifyUnifiedJson(data).toArray())
            @Expect(session.decide(parent.operationId.value, ApprovalDecision.Approve).isError())
            // Ordinary parent approval preflight keeps the original waiting
            // owner on configuration failure; only explicit cancel settles it.
            @Expect(session.approval().getOrThrow().operationId.value, parent.operationId.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 0)
            @Expect(session.cancel().isOk())
            @Expect(f.snapshot("provider-approval-change").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func documentAllocationConfigurationCannotSupplyAnAuthorityOrForeignProfile(): Unit {
        let original = objectValue([ValueField("name", textValue("todo")), ValueField("documents", listValue([]))])
        @Expect(productDocumentToolConfigurationValid(original))
        for (bad in [ValueField("preparation_provider", integerValue(1)), ValueField("preparation_provider", textValue("../foreign")),
            ValueField("capabilities", listValue([])), ValueField("tool_payload_limits", OrdinaryToolPayloadLimits("todo").value())]) {
            let value = parseUnifiedJson(stringifyUnifiedJson(original)); value.put(bad.name, bad.value)
            @Expect(!productDocumentToolConfigurationValid(value))
        }
        original.put("preparation_provider", textValue("prepare_document"))
        original.put("tool_payload_limits", OrdinaryToolPayloadLimits("goal").value())
        @Expect(!productDocumentToolConfigurationValid(original))
        original.put("tool_payload_limits", OrdinaryToolPayloadLimits("todo").value())
        @Expect(productDocumentToolConfigurationValid(original))
    }
    @TestCase
    func actualGoalToolUsesCanonicalObservationAndKeepsAllMutationsInPluginDocuments(): Unit {
        let f = WorkflowDocumentFixture()
        try {
            let thread = "workflow-goal"
            let before = lifecycleTestRequire(f.product.sessionRunStats(SessionId(thread)))
            let created = f.call(thread, objectValue([ValueField("op", textValue("create")),
                ValueField("objective", textValue("Complete the installed migration")), ValueField("token_budget", integerValue(100))]), localName: "goal")
            @Expect(!created.isError)
            let initial = f.snapshot(thread, key: "goal").decode().value().getOrThrow()
            @Expect(initial.field("baselineTokens").getOrThrow().asNumberText(), (before.inputTokens + before.outputTokens).toString())
            @Expect(httpIntentText(initial, "objective"), "Complete the installed migration")
            @Expect(initial.field("tokenBudget").getOrThrow().asNumberText(), "100")
            for (op in ["get", "resume", "complete", "drop"]) {
                @Expect(!f.call(thread, objectValue([ValueField("op", textValue(op))]), localName: "goal").isError)
            }
            @Expect(f.snapshot(thread, key: "goal").decode().value().getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 15)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 5)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE goal_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func modelGoalDocumentAccountingCannotResumeOrEnlargePausedHostAllowance(): Unit {
        let f = WorkflowDocumentFixture()
        try {
            let thread = "workflow-goal-allowance"
            @Expect(!f.call(thread, objectValue([ValueField("op", textValue("create")), ValueField("objective", textValue("bounded work")),
                ValueField("token_budget", integerValue(10))]), localName: "goal").isError)
            let repository = ContinuationAllowanceRepository(SqliteRunRepository(f.database))
            let address = ContinuationAllowanceAddress(ThreadId(thread), LaneId("main"), productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), "goal")
            // Test-only host accounting seed, explicitly not an Application user
            // control or a Run admission. The actual plugin cannot call it.
            let initial = lifecycleTestRequire(f.database.transaction<Result<ContinuationAllowanceFacts>>({ tx =>
                repository.appendControlFacts(tx, address, None, ContinuationAllowanceControl.Create("actual-host-allowance", Some(10)),
                    modelPolicySha256Text("test-host-control"), agentUtcMillis()) }))
            let paused = lifecycleTestRequire(f.database.transaction<Result<ContinuationAllowanceFacts>>({ tx =>
                repository.appendControlFacts(tx, address, Some(initial), ContinuationAllowanceControl.Pause,
                    modelPolicySha256Text("test-host-pause"), agentUtcMillis()) }))
            @Expect(!paused.hasRemainingTokens())
            let altered = f.call(thread, objectValue([ValueField("method", textValue("budget")), ValueField("token_budget", integerValue(999999)),
                ValueField("tokensUsed", integerValue(0)), ValueField("baselineTokens", integerValue(0)), ValueField("enabled", boolValue(true))]), localName: "goal")
            @Expect(!altered.isError)
            @Expect(f.snapshot(thread, key: "goal").decode().value().getOrThrow().field("tokenBudget").getOrThrow().asNumberText(), "999999")
            let actual = lifecycleTestRequire(f.database.transaction<Result<?ContinuationAllowanceFacts>>({ tx => repository.readFacts(tx, address) })).getOrThrow()
            @Expect(actual.eventId, paused.eventId); @Expect(actual.revision, paused.revision)
            @Expect(actual.tokenBudget.getOrThrow(), 10); @Expect(actual.tokensUsed, paused.tokensUsed)
            @Expect(!actual.enabled); @Expect(!actual.hasRemainingTokens())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='workflow-goal-allowance'"), 2)
        } finally { f.close() }
    }

    @TestCase
    func corruptActualRunStatisticsNeverBecomeAZeroUsageGoalRead(): Unit {
        let f = WorkflowDocumentFixture()
        try {
            let thread = "workflow-goal-corrupt"
            @Expect(!f.call(thread, objectValue([ValueField("op", textValue("create")), ValueField("objective", textValue("keep original"))]), localName: "goal").isError)
            let before = f.snapshot(thread, key: "goal")
            // Simulate damaged historical accounting through the deliberate DB
            // corruption seam; no production writer may save this payload.
            f.database.execute("UPDATE runs SET app_snapshot=? WHERE thread_id=?",
                [SqlParameter.Text("{corrupt-actual-snapshot"), SqlParameter.Text(thread)])
            let result = f.product.vnext.executeCanonicalTool(SessionId(thread),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("read-corrupt-goal", "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal", objectValue([ValueField("op", textValue("get"))])))
            @Expect(match (result) { case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            @Expect(f.snapshot(thread, key: "goal").revision, before.revision)
            @Expect(f.snapshot(thread, key: "goal").encoded, before.encoded)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 1)
        } finally { f.close() }
    }

    @TestCase
    func actualPackageTodoInitViewDoneUsesOnlyCanonicalDocumentReceipts(): Unit {
        let f = WorkflowDocumentFixture()
        try {
            let initialized = f.call("workflow-todo", objectValue([ValueField("op", textValue("init")),
                ValueField("items", listValue([textValue("first"), textValue("second")]))]))
            @Expect(!initialized.isError)
            @Expect(httpIntentText(initialized.output, "storage"), "session")
            let initial = f.snapshot("workflow-todo")
            @Expect(initial.revision, 1)
            let view = f.call("workflow-todo", objectValue([ValueField("op", textValue("view"))]))
            @Expect(!view.isError); @Expect(f.snapshot("workflow-todo").revision, 1)
            @Expect(canonicalAgentValue(view.output.field("phases").getOrThrow()), canonicalAgentValue(initial.decode().value().getOrThrow()))
            let done = f.call("workflow-todo", objectValue([ValueField("op", textValue("done")), ValueField("task", textValue("first"))]))
            @Expect(!done.isError); @Expect(f.snapshot("workflow-todo").revision, 2)
            @Expect(done.output.field("completedTasks").getOrThrow().items.size, 1)
            @Expect(httpIntentText(done.output.field("completedTasks").getOrThrow().items[0], "content"), "first")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='workflow-todo'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE todo_payload<>''"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualPackageCommittedTodoReadApprovalDoesNotApproveDocumentMutation(): Unit {
        let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk)
        try {
            let session = f.product.applicationSession(sessionId: Some(SessionId("workflow-approved")))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("workflow-approved", f.tool,
                objectValue([ValueField("op", textValue("init")), ValueField("items", listValue([textValue("actual task")]))]))
            @Expect(session.submit("Create the exact reviewed task document.").isOk())
            let read = session.approval().getOrThrow(); @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(f.snapshot("workflow-approved").revision, 0)
            @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = session.approval().getOrThrow(); @Expect(mutation.toolName, f.tool)
            @Expect(mutation.operationId.value != read.operationId.value)
            @Expect(f.snapshot("workflow-approved").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(session.decide(mutation.operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(f.snapshot("workflow-approved").revision, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='workflow-approved'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 1)
        } finally { f.close() }
    }

    @TestCase
    func mixedProviderServiceRequestsAndClaimedToolKindCreateNoCanonicalAuthority(): Unit {
        for (mode in ["read", "compare_exchange"]) {
            let root = pluginContractTemp("mixed-provider-document")
            Directory.create(root + "/workspace", recursive: true)
            let product = workspacePluginOpen(root, ApprovalMode.Yolo)
            let database = SqliteDatabase(root + "/state/state.db")
            let cancellation = CancellationSource()
            try {
                let source = root + "/hostile-package"; Directory.create(source)
                File.writeTo(source + "/main.py", File.readFrom(getVariable("AXYNDRA_WORKFLOW_MIXED_FIXTURE").getOrThrow()))
                let chmod = workflow_test_process.runProcess(workflow_test_process.ProcessCommand("/usr/bin/chmod",
                    arguments: ["700", source + "/main.py"], maxOutputBytes: 4096))
                @Expect(chmod.status.code, 0)
                File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
                    ValueField("id", textValue("workflow-hostile")), ValueField("version", textValue("1.0.0")),
                    ValueField("entry_kind", textValue("native-executable")), ValueField("entrypoint", textValue("main.py")),
                    ValueField("sdk_range", textValue("[2.1.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
                    ValueField("capabilities", listValue([textValue("document.store")])), ValueField("contributions", listValue([
                        objectValue([ValueField("kind", textValue("tool")), ValueField("name", textValue("update"))]),
                        objectValue([ValueField("kind", textValue("provider")), ValueField("name", textValue("propose"))])]))])).toArray())
                let record = match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
                    case PluginRegistryResult.Ok(value) => value; case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
                @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace).isOk())
                let input = objectValue([ValueField("mode", textValue(mode)), ValueField("kind", textValue("tool")),
                    ValueField("operation_id", textValue("forged-operation")), ValueField("run_id", textValue("forged-run"))])
                @Expect(queryProductPluginPolicy(product.vnext.javascriptPlugins, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "update",
                    productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), input, ThreadId("provider-no-run"), cancellation.token, "wrong-contribution").isError())
                @Expect(queryProductPluginPolicy(product.vnext.javascriptPlugins, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "propose",
                    productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), input, ThreadId("provider-no-run"), cancellation.token, "hostile-provider").isError())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            } finally { cancellation.close(); database.close(); let _ = product.close(); remove(root, recursive: true) }
        }
    }

    @TestCase
    func actualPackageMalformedOldDocumentAndBusinessErrorCannotOverwriteHistory(): Unit {
        let f = WorkflowDocumentFixture()
        try {
            let invalid = f.call("workflow-invalid", objectValue([ValueField("op", textValue("init")),
                ValueField("items", listValue([textValue("duplicate"), textValue("duplicate")]))]))
            @Expect(invalid.isError); @Expect(httpIntentText(invalid.output, "summary").startsWith("Errors: "))
            @Expect(f.snapshot("workflow-invalid").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 1)
            let initial = f.call("workflow-malformed", objectValue([ValueField("op", textValue("init")), ValueField("items", listValue([textValue("keep")]))]))
            @Expect(!initial.isError)
            let prior = f.snapshot("workflow-malformed")
            let corrupt = "{historical-malformed-bytes"
            f.database.execute("UPDATE plugin_documents SET payload=? WHERE thread_id=? AND namespace=? AND document_key='todo'",
                [SqlParameter.Text(corrupt), SqlParameter.Text("workflow-malformed"), SqlParameter.Text(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))])
            let outcome = f.product.vnext.executeCanonicalTool(SessionId("workflow-malformed"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("malformed-old", f.tool, objectValue([ValueField("op", textValue("view"))])))
            @Expect(match (outcome) { case Result.Err(_) | Result.Ok(ToolInvocationResult.Denied(_)) => true
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError; case _ => false })
            @Expect(f.snapshot("workflow-malformed").encoded, corrupt)
            @Expect(f.snapshot("workflow-malformed").revision, prior.revision)
        } finally { f.close() }
    }
}

func workflowDocumentTestAllowance(fixture: WorkflowDocumentFixture, thread: String): ?ContinuationAllowanceFacts {
    let repository = SqliteRunRepository(fixture.database)
    lifecycleTestRequire(fixture.database.readTransaction<Result<?ContinuationAllowanceFacts>>({ transaction =>
        ContinuationAllowanceRepository(repository).readFacts(transaction,
            ContinuationAllowanceAddress(ThreadId(thread), LaneId("main"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "goal")) }))
}


@Test
class PayloadDocumentPreparationRejectionTests {
    @TestCase
    func unownedPayloadGoalControlSettlesItsOriginalParentBeforeAnyDurablePin(): Unit {
        let fixture = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            // Actual native Workflow + canonical read, without an Application
            // command participant. The proposed control must fail closed.
            let result = fixture.call("goal-payload-control-rejected",
                objectValue([ValueField("command_args", textValue("set cannot manufacture an actual user owner"))]), localName: "goal")
            try { @Expect(result.isError, true) } finally { result.releasePayload() }
            @Expect(fixture.snapshot("goal-payload-control-rejected", key: "goal").revision, 0)
            @Expect(workflowDocumentTestAllowance(fixture, "goal-payload-control-rejected").isNone())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_direct_preparation_rejection_only'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind IN ('plugin_document_payload_prepared','plugin_document_result_prepared')"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing','recovery_required','unknown')"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
        } finally { fixture.close() }
    }
}
