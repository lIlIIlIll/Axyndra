package agent_product

import agent_core.*
import agent_domain.*
import tool_runtime.ApprovalMode
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func initialContextTestConfig(f: SkillsProviderProductFixture, digest!: String = "", extra!: Bool = false, dataRoot!: String = ""): String {
    let directory = f.root + "/settings/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let root = if (dataRoot == "") { f.root + "/context-data" } else { dataRoot }
    let source = root + "/review/SKILL.md"
    if (!exists(Path(root))) { writeObservedSkill(root, "App-selected immutable instructions\n") }
    let value = objectValue([ValueField("version", integerValue(1)),
        ValueField("namespace", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest", textValue(if (digest == "") { productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)) } else { digest })),
        ValueField("provider", textValue("skills")),
        ValueField("resources", listValue([skillsReadResource(source, "selected/review/SKILL.md", mode: "file")])),
        ValueField("query", objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")),
            ValueField("action", textValue("resolve")), ValueField("resource_roots", listValue([textValue("selected")])),
            ValueField("include_catalog", boolValue(true))])), ValueField("prompt_field", textValue("prompt"))])
    let text = stringifyUnifiedJson(value) + if (extra) { "\n " } else { "\n" }
    File.writeTo(directory + "/context.json", text.toArray()); text
}
func initialContextOnlyRun(f: SkillsProviderProductFixture): RunId {
    let rows = f.database.query("SELECT id FROM runs")
    @Expect(rows.size, 1); RunId(rows[0].required(0))
}
func initialContextStored(f: SkillsProviderProductFixture): InvocationContextProjection {
    contextSnapshotFromValue(decodeStoredValue(f.database.query("SELECT skill_snapshot FROM runs")[0].required(0)))
}
func initialContextHandoffs(f: SkillsProviderProductFixture): Int64 {
    f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'")
}
func initialContextNoOpenWork(f: SkillsProviderProductFixture): Unit {
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"),
        f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"))
}

@Test
class PluginInitialContextTests {
    @TestCase
    func interruptedAcceptedPreparationIsRetainedAndExplicitlyNonReplayableAfterReopen(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let first = SqliteDatabase(root + "/state.db")
        let thread = ThreadId("initial-interrupted-thread"); let run = RunId("initial-interrupted-run")
        let input = ThreadItemContent.UserMessage(textMessageParts("actual initial prompt"))
        let lane = ModelLane(ModelLaneRole.Main, "fixture", "fixture-model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("initial-tools", []), "system-v1")
        var encoded = ""
        try {
            let sink = SqliteThreadCommitSink(first)
            let runtime = AgentThreadRuntime(ThreadCoordinator(sink.createThread(thread, "workspace"), sink),
                ContextProjector("initial-context", ConservativeThreadTokenEstimator()), { => 20 })
            let active = lifecycleTestRequire(runtime.startTurn(SemanticTurnId("initial-turn"), run, ItemId("initial-user"),
                input, lane, InvocationContextProjection(), createdAtMillis: 1))
            let request = objectValue([ValueField("schema", textValue("axyndra.accepted-context-request/v1")),
                ValueField("run_id", textValue(run.value)), ValueField("session_id", textValue(thread.value)),
                ValueField("epoch", integerValue(active.epoch)), ValueField("model", textValue(lane.modelId)),
                ValueField("prompt", textValue("actual initial prompt")), ValueField("system", textValue("frozen base system")),
                ValueField("skill_stack", contextSnapshotValue(InvocationContextProjection())), ValueField("lane_id", textValue("main")),
                ValueField("budget", objectValue([])), ValueField("tool_context", objectValue([])), ValueField("capabilities", listValue([]))])
            @Expect(SqliteRunRepository(first).bindAcceptedContextRequest(run, SessionId(thread.value), active.epoch, input, request, 20).isOk())
            encoded = first.query("SELECT payload FROM run_continuations")[0].required(0)
        } finally { first.close() }
        let reopened = SqliteDatabase(root + "/state.db")
        try {
            let result = SqliteRunRepository(reopened).pendingRecoveryContinuation(SessionId(thread.value))
            @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "context.initial_preparation_interrupted")
            @Expect(!result.error().getOrThrow().retryable)
            @Expect(reopened.query("SELECT payload FROM run_continuations")[0].required(0), encoded)
            @Expect(reopened.query("SELECT state FROM runs")[0].required(0), "running")
            @Expect(reopened.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 1)
            @Expect(reopened.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(reopened.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            let durable = decodeDurableRunContinuation(encoded)
            @Expect(isInitialContextRequest(optionalRunRequestSnapshotFromDurableContinuation(durable).getOrThrow()))
            @Expect(durable.attemptId.isNone()); @Expect(durable.pendingApprovalId.isNone())
        } finally { reopened.close(); remove(root, recursive: true) }
    }

    @TestCase
    func applicationAutoSelectionUsesActualReadBeforeItsFirstModelRequest(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            initialContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let response = lifecycleTestRequire(app.submit("$review"))
            @Expect(response.approval.isNone()); @Expect(response.snapshot.getOrThrow().status, RunState.Completed)
            @Expect(skillsReadCount(f, "completed"), 1)
            @Expect(initialContextHandoffs(f), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='initial_context_request_bound'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            let firstModel = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
            @Expect(firstModel.system.contains("App-selected immutable instructions"))
            @Expect(firstModel.system.contains("Available Skills"))
            let snapshot = initialContextStored(f)
            @Expect(snapshot.contributions().size, 1)
            @Expect(snapshot.contributions()[0].trust, ContextContentTrust.UntrustedData)
            let fact = lifecycleTestRequire(DurableOperationStore(f.database).loadContextReadFact(
                OperationId(f.database.query("SELECT operation_id FROM operation_effect_records WHERE tool_id=?",
                    [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])[0].required(0)), initialContextOnlyRun(f)))
            @Expect(fact.origin.parentCallItemId, "")
            @Expect(fact.origin.projectionDigest, contextReadProjectionDigest(InvocationContextProjection()))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            initialContextNoOpenWork(f)
        } finally { f.close() }
    }

    @TestCase
    func actualApplicationReadApprovalHasNoPriorModelOrBodyAndCannotBeReusedAfterConfigChange(): Unit {
        for (mode in ["approve", "reject", "change", "cancel"]) {
            let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                initialContextTestConfig(f, dataRoot: f.root + "/settings/skills")
                let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
                let response = lifecycleTestRequire(contextDiagnosticApp(f, "actualApplicationReadApprovalHasNoPriorModelOrBodyAndCannotBeReusedAfterConfigChange", app.submit("$review")))
                let approval = response.approval.getOrThrow()
                @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                @Expect(initialContextHandoffs(f), 0); @Expect(skillsReadCount(f, "completed"), 0)
                if (mode == "change") { initialContextTestConfig(f, extra: true, dataRoot: f.root + "/settings/skills") }
                if (mode == "cancel") { @Expect(app.cancel().isOk()) }
                else {
                    let outcome = contextDiagnosticApp(f, "initial-approval-mode-" + mode,
                        app.decide(approval.operationId.value,
                            if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve }))
                    if (mode == "approve") { @Expect(outcome.isOk()) }
                    else {
                        @Expect(outcome.isError())
                        @Expect(outcome.error().getOrThrow().code,
                            if (mode == "reject") { "context.read_failed" } else { "context.initial_configuration_changed" })
                    }
                }
                if (mode == "approve") {
                    @Expect(skillsReadCount(f, "completed"), 1)
                    @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("App-selected immutable instructions"))
                } else {
                    @Expect(skillsReadCount(f, "completed"), 0)
                    @Expect(initialContextHandoffs(f), 0)
                    @Expect(initialContextStored(f).contributions().isEmpty())
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                    @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                }
                if (mode == "change" || mode == "reject") {
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                }
                initialContextNoOpenWork(f)
            } finally { f.close() }
        }
    }

    @TestCase
    func configuredProviderHasExactPackageBindingAndExplicitFrozenContextBypassesAutoSelection(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            initialContextTestConfig(f, digest: "sha256:" + String.fromUtf8(Array<Byte>(64, repeat: b'0')))
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let result = app.submit("$review")
            @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "context.initial_binding_changed")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            let immutable = InvocationContextProjection(contributions: [InvocationContextContribution("caller", "fixed", "caller:fixed",
                "Explicit caller-frozen content", ContextContentTrust.UntrustedData)])
            let request = f.product.request("Use frozen content", sessionId: Some(SessionId("explicit-context-thread")), contextSnapshot: Some(immutable))
            @Expect(!request.initializeContext)
            @Expect(f.product.client.start(request, { _ => () }).isOk())
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("Explicit caller-frozen content"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }

    @TestCase
    func committedInitialContentStaysInspectableAfterRevocationAndDatabaseReopen(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            initialContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(app.submit("$review").isOk())
            let raw = f.database.query("SELECT skill_snapshot FROM runs")[0].required(0)
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            File.writeTo(f.root + "/context-data/review/SKILL.md", "changed after canonical observation".toArray())
            let reopened = SqliteDatabase(f.root + "/state/state.db")
            try {
                @Expect(reopened.query("SELECT skill_snapshot FROM runs")[0].required(0), raw)
                @Expect(contextSnapshotFromValue(decodeStoredValue(raw)).contributions()[0].content.contains("App-selected immutable instructions"))
                @Expect(SqliteRunRepository(reopened).pendingRecoveryContinuation(SessionId(f.thread.value)).value().getOrThrow().isNone())
            } finally { reopened.close() }
        } finally { f.close() }
    }
}
