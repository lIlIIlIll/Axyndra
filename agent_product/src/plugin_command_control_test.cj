package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class WorkflowCommandFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: agent_plugin_registry.ProductPluginRecord
    let session: ApplicationSession
    init(mode!: ApprovalMode = ApprovalMode.AlwaysAsk) {
        let path = pluginContractTemp("installed-workflow-command")
        Directory.create(path + "/workspace", recursive: true)
        let product = workspacePluginOpen(path, mode)
        let imported = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
            case PluginRegistryResult.Ok(value) => value; case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
        let tools = ArrayList<AgentValue>()
        for (name in ["todo", "goal"]) {
            tools.add(objectValue([ValueField("name", textValue(name)), ValueField("documents", listValue([objectValue([
                ValueField("key", textValue(name)), ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])]))])) }
        if (!exists(Path(path + "/settings/plugins"))) { Directory.create(path + "/settings/plugins", recursive: true) }
        File.writeTo(path + "/settings/plugins/documents.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(imported.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("package_digest", textValue(productRegistryCopyText83(imported.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("tools", listValue(tools.toArray()))])]))])).toArray())
        match (product.setPluginEnabled(productRegistryCopyText83(imported.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.Workspace)) {
            case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
        this.root = path; this.product = product; this.record = imported
        this.database = SqliteDatabase(path + "/state/state.db")
        this.session = product.applicationSession(sessionId: Some(SessionId("workflow-command-user")))
    }
    func command(name: String, text: String): Result<Unit> {
        session.invokeJavaScriptPluginCommand("plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "." + name, text, { _, _ => () })
    }
    func facts(): ?ContinuationAllowanceFacts {
        // A read of accounting is not a live owner. Tests never manufacture a
        // control audit or use this query to bypass the actual user Command.
        let repository = SqliteRunRepository(database)
        database.readTransaction<Result<?ContinuationAllowanceFacts>>({ tx =>
            ContinuationAllowanceRepository(repository).readFacts(tx,
                ContinuationAllowanceAddress(ThreadId(session.id().value), LaneId("main"), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "goal")) }).value().getOrThrow()
    }
    func document(key: String): PluginDocumentSnapshot {
        SqlitePluginDocumentRepository(database).read(ThreadId(session.id().value), LaneId("main"), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), key).value().getOrThrow()
    }
    func close(): Unit { let _ = session.cancel(); database.close(); let _ = product.close(); remove(root, recursive: true) }
}

@Test
class PluginCommandControlTests {
    @TestCase
    func installedTodoCommandUsesCommonApplicationApprovalWithoutReparsing(): Unit {
        let f = WorkflowCommandFixture()
        try {
            @Expect(f.command("todo", "{\"op\":\"init\",\"items\":[\"frozen command task\"]}").isOk())
            let read = f.session.approval().getOrThrow()
            @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            let invalid = f.session.decide(read.operationId.value, ApprovalDecision.ApproveSession)
            @Expect(invalid.isError()); @Expect(invalid.error().getOrThrow().code, "approval.session_scope_forbidden")
            @Expect(f.session.approval().getOrThrow().operationId.value, read.operationId.value)
            @Expect(f.session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = f.session.approval().getOrThrow()
            @Expect(mutation.operationId.value != read.operationId.value)
            @Expect(f.document("todo").revision, 0)
            @Expect(f.session.decide(mutation.operationId.value, ApprovalDecision.Approve).isOk())
            @Expect(f.session.approval().isNone()); @Expect(f.document("todo").revision, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func rejectCancelAndDisableRetireOnlyTheActualFrozenCommand(): Unit {
        for (mode in ["reject", "cancel", "disable"]) {
            let f = WorkflowCommandFixture()
            try {
                @Expect(f.command("todo", "{\"op\":\"init\",\"items\":[\"must not persist\"]}").isOk())
                let read = f.session.approval().getOrThrow()
                if (mode == "cancel") { @Expect(f.session.cancel().isOk()) }
                else if (mode == "reject") { let _ = f.session.decide(read.operationId.value, ApprovalDecision.Reject) }
                else {
                    @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false, PluginInstallScope.Workspace).isOk())
                    let _ = f.session.decide(read.operationId.value, ApprovalDecision.Approve)
                }
                @Expect(f.session.approval().isNone()); @Expect(f.document("todo").revision, 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func commandResponseWithoutActualApplicationScopeCannotCreateRunOrDocument(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        let cancellation = CancellationSource()
        try {
            let result = f.product.invokeJavaScriptPluginCommand("plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".todo",
                "{\"op\":\"init\",\"items\":[\"no user scope\"]}", f.session.id(), "no-user-owner", cancellation.token, { _, _ => () })
            @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "plugin.command_user_scope_required")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.document("todo").revision, 0)
        } finally { cancellation.close(); f.close() }
    }

    @TestCase
    func goalCommandCommitsDocumentReceiptAndUserAllowanceTogetherThenPauses(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "Complete the bounded test task").isOk())
            let created = f.facts().getOrThrow()
            @Expect(created.enabled); @Expect(!created.closed); @Expect(created.tokensUsed, 0)
            @Expect(f.document("goal").revision, 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 1)
            @Expect(f.command("goal", "pause").isOk())
            let paused = f.facts().getOrThrow(); @Expect(!paused.enabled); @Expect(paused.generation, created.generation + 1)
            @Expect(f.session.submit("Return a short acknowledgement.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func goalDeferredControlIsFrozenOnlyAfterItsActualReadAndVisibleBeforeMutation(): Unit {
        let f = WorkflowCommandFixture()
        try {
            @Expect(f.command("goal", "A visibly reviewed user objective").isOk())
            let read = f.session.approval().getOrThrow()
            @Expect(read.preview.field("host_user_control").isNone())
            @Expect(read.preview.field("host_user_control_pending").isSome())
            @Expect(read.preview.field("command_input").getOrThrow().field("command_args").isSome())
            @Expect(f.facts().isNone())
            @Expect(f.session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let write = f.session.approval().getOrThrow()
            let finalControl = write.preview.field("host_user_control").getOrThrow()
            @Expect(httpIntentText(finalControl, "action"), "create")
            @Expect(finalControl.field("next_prompt").isSome())
            @Expect(finalControl.field("token_budget").getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(write.preview.field("command_proposal_digest").getOrThrow().text !=
                read.preview.field("command_proposal_digest").getOrThrow().text)
            let invalid = f.session.decide(write.operationId.value, ApprovalDecision.ApproveSession)
            @Expect(invalid.isError()); @Expect(invalid.error().getOrThrow().code, "approval.session_scope_forbidden")
            @Expect(f.session.approval().getOrThrow().operationId.value, write.operationId.value)
            @Expect(canonicalAgentValue(f.session.approval().getOrThrow().preview.field("host_user_control").getOrThrow()),
                canonicalAgentValue(finalControl))
            @Expect(f.session.decide(write.operationId.value, ApprovalDecision.Reject).isError())
            @Expect(f.facts().isNone()); @Expect(f.document("goal").revision, 0)
        } finally { f.close() }
    }

    @TestCase
    func newApplicationOwnerCannotRecoverContinuationAuthorityFromFacts(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "Historical data is not a continuation owner").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            let original = f.facts().getOrThrow()
            let other = f.product.applicationSession(sessionId: Some(f.session.id()))
            @Expect(other.submit("Return one short acknowledgement.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
            @Expect(f.facts().getOrThrow().eventId, original.eventId)
            @Expect(f.session.cancel().isOk())
            @Expect(f.session.submit("A cancelled owner cannot continue either.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualUserBudgetAdmitsTypedCoreContinuationsAndStopsBetweenRuns(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "Continue with brief acknowledgements").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            @Expect(f.session.submit("Acknowledge this bounded goal.").isOk())
            let count = f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'")
            @Expect(count > 0); @Expect(count < 64)
            @Expect(!f.facts().getOrThrow().hasRemainingTokens())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'"), count)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts") > count)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"), 0)
            let reopened = SqliteDatabase(f.root + "/state/state.db")
            try { @Expect(reopened.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), count) }
            finally { reopened.close() }
        } finally { f.close() }
    }

    @TestCase
    func failedAllowanceWriteRollsBackActualDocumentCasAndChildReceipt(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            f.database.execute("CREATE TRIGGER continuation_control_fail BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind LIKE 'host_continuation_accounting_v1:%' BEGIN SELECT RAISE(ABORT,'fixture control'); END")
            @Expect(f.command("goal", "Must roll back its document").isError())
            @Expect(f.document("goal").revision, 0); @Expect(f.facts().isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func ordinaryGoalMutationCannotIncreaseOrResumeActualUserAllowance(): Unit {
        let f = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            @Expect(f.command("goal", "Only an actual user may continue").isOk())
            @Expect(f.command("goal", "budget 64").isOk())
            let before = f.facts().getOrThrow()
            let outcome = f.product.vnext.executeCanonicalTool(f.session.id(),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))]),
                ToolCall("ordinary-complete", "plugin." + productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".goal",
                    objectValue([ValueField("op", textValue("complete"))])))
            @Expect(match (outcome) { case Result.Ok(ToolInvocationResult.Completed(value)) => !value.isError; case _ => false })
            match (outcome) { case Result.Ok(ToolInvocationResult.Completed(value)) => value.releasePayload(); case _ => () }
            let after = f.facts().getOrThrow(); @Expect(after.eventId, before.eventId); @Expect(after.tokenBudget, before.tokenBudget)
            @Expect(f.session.submit("Give a short acknowledgement.").isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { f.close() }
    }
}


// Descriptive user-control data only; no Run/source/approval is constructed.
func commandRestrictionCodecControl(selector: AgentValue): AgentValue {
    objectValue([ValueField("kind", textValue("continuation")), ValueField("document_key", textValue("goal")),
        ValueField("action", textValue("create")), ValueField("token_budget", nullValue()),
        ValueField("next_prompt", textValue("A bounded actual user objective")), ValueField("restriction", objectValue([
            ValueField("provider", textValue("propose")), ValueField("selector", selector)]))])
}

@Test
class PluginCommandRestrictionCodecTests {
    @TestCase
    func validNativeSelectorAndEscapedJsonKeepTheirCanonicalIdentity(): Unit {
        let selector = objectValue([ValueField("action", textValue("goal_continuation"))])
        @Expect(validateCommandContinuationControl(commandRestrictionCodecControl(selector)).isOk())
        selector.put("quoted", textValue("quote \" and newline\n雪"))
        selector.put("nested", objectValue([ValueField("flag", boolValue(true)), ValueField("value", nullValue())]))
        @Expect(validateCommandContinuationControl(commandRestrictionCodecControl(selector)).isOk())
    }

    @TestCase
    func restrictionShapeUnknownFieldsAndOriginalByteCeilingsStillReject(): Unit {
        let selector = objectValue([ValueField("action", textValue("goal_continuation"))])
        let unknown = commandRestrictionCodecControl(selector)
        unknown.field("restriction").getOrThrow().put("unexpected", boolValue(true))
        let unknownResult = validateCommandContinuationControl(unknown)
        @Expect(unknownResult.isError()); @Expect(unknownResult.error().getOrThrow().code, "plugin.command_restriction_invalid")
        let wrongShape = validateCommandContinuationControl(commandRestrictionCodecControl(textValue("goal_continuation")))
        @Expect(wrongShape.isError()); @Expect(wrongShape.error().getOrThrow().code, "plugin.command_restriction_invalid")
        let oversized = validateCommandContinuationControl(commandRestrictionCodecControl(objectValue([
            ValueField("action", textValue(String.fromUtf8(Array<Byte>(4097, repeat: b'x'))))])))
        @Expect(oversized.isError()); @Expect(oversized.error().getOrThrow().code, "plugin.command_restriction_invalid")
        let provider = commandRestrictionCodecControl(selector)
        provider.field("restriction").getOrThrow().put("provider", textValue("../propose"))
        @Expect(validateCommandContinuationControl(provider).isError())
        let pause = commandRestrictionCodecControl(selector)
        pause.put("action", textValue("pause"))
        @Expect(validateCommandContinuationControl(pause).isError())
    }

    @TestCase
    func actualRestrictionCopiesItsSelectorWithoutMintingARun(): Unit {
        let fixture = WorkflowCommandFixture(mode: ApprovalMode.Yolo)
        try {
            let host = fixture.product.vnext.javascriptPlugins
            let commands = host.commands().filter { item => item.extensionId == productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)) && item.name == "goal" }
            @Expect(commands.size, 1)
            let binding = ProductCommandBinding(host, commands[0], fixture.record.descriptor)
            @Expect(binding.verify().isOk())
            let configuration = host.documentConfiguration(binding.namespace, binding.digest).value().getOrThrow()
            let selector = objectValue([ValueField("action", textValue("goal_continuation"))])
            let selected = ProductContinuationRestriction(binding, configuration, "propose", "plugin." + binding.namespace + ".goal", selector)
            @Expect(selected.current("goal").isOk())
            selector.put("action", textValue("changed source"))
            @Expect(httpIntentText(selected.selector(), "action"), "goal_continuation")
            let returned = selected.selector()
            returned.put("action", textValue("changed returned copy"))
            @Expect(httpIntentText(selected.selector(), "action"), "goal_continuation")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'"), 0)
        } finally { fixture.close() }
    }
}
