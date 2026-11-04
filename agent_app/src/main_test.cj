package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_tui.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TuiRunEventCursorTests {
    @TestCase
    func lateEventsCannotCrossUiRunGeneration(): Unit {
        let cursor = TuiRunEventCursor()
        cursor.begin()
        @Expect(!cursor.accept(appCursorEvent(1, "old", AgentEventPayload.TextDelta("late"))))
        @Expect(cursor.accept(appCursorEvent(1, "run-a", AgentEventPayload.RunStarted)))
        @Expect(cursor.accept(appCursorEvent(2, "run-a", AgentEventPayload.TextDelta("a"))))
        @Expect(!cursor.accept(appCursorEvent(3, "run-b", AgentEventPayload.TextDelta("wrong"))))
        @Expect(cursor.accept(appCursorEvent(3, "run-a", AgentEventPayload.RunCompleted)))
        @Expect(!cursor.accept(appCursorEvent(4, "run-a", AgentEventPayload.TextDelta("late-a"))))
        @Expect(cursor.accept(appCursorEvent(1, "run-b", AgentEventPayload.RunStarted)))

        cursor.begin(expectedRunId: "approval-run")
        @Expect(!cursor.accept(appCursorEvent(1, "other", AgentEventPayload.TextDelta("wrong"))))
        @Expect(cursor.accept(appCursorEvent(
            1, "approval-run",
            AgentEventPayload.RunStateChanged(
                RunState.WaitingApproval, RunState.Running, "approved"
            )
        )))
        cursor.finish()
        @Expect(!cursor.accept(appCursorEvent(
            2, "approval-run", AgentEventPayload.TextDelta("after-finish")
        )))
    }
    @TestCase
    func delayedSyntheticEventsCannotCrossUiRunGeneration(): Unit {
        let cursor = TuiRunEventCursor()
        cursor.begin()
        @Expect(cursor.accept(appCursorEvent(
            1, "run-a", AgentEventPayload.RunStarted
        )))
        @Expect(cursor.accept(appCursorEvent(
            2, "run-a", AgentEventPayload.RunCompleted
        )))

        cursor.begin()
        @Expect(cursor.accept(appCursorEvent(
            3, "run-b", AgentEventPayload.RunStarted
        )))
        @Expect(!cursor.accept(appCursorEvent(
            4,
            "compaction-session",
            AgentEventPayload.ContextCompacted(100, 60)
        )))
        @Expect(!cursor.accept(appCursorEvent(
            5,
            "compaction-session",
            AgentEventPayload.Extension(
                AgentEventKind.Transcript,
                objectValue([
                    ValueField("code", textValue("run.summary")),
                    ValueField("text", textValue("stale summary"))
                ])
            )
        )))
        @Expect(cursor.accept(appCursorEvent(
            6, "run-b", AgentEventPayload.RunCompleted
        )))
        @Expect(cursor.accept(appCursorEvent(
            7,
            "compaction-session",
            AgentEventPayload.ContextCompacted(100, 60)
        )))
    }

}

func appCursorEvent(sequence: Int64, runId: String, payload: AgentEventPayload): AgentEvent {
    AgentEvent(EventMeta(sequence, TraceId("trace-" + runId), RunId(runId)), payload)
}

@Test
class RestoredTranscriptTests {
    @TestCase
    func toolCallAndResultRestoreAsOneSpecializedCard(): Unit {
        let messages = [
            ModelMessage(
                ModelRole.Assistant,
                [
                    ModelBlock(
                        ModelBlockKind.ToolCall,
                        callId: "call-restore-1",
                        name: "bash",
                        arguments: objectValue([
                            ValueField("command", textValue("cargo test")),
                            ValueField("cwd", textValue("/tmp/project"))
                        ])
                    )
                ]
            ),
            ModelMessage(
                ModelRole.User,
                [
                    ModelBlock(
                        ModelBlockKind.ToolResult,
                        text: "tests passed",
                        callId: "call-restore-1"
                    )
                ]
            )
        ]

        let items = tuiTranscriptItems(messages, "main")

        @Expect(items.size, 1)
        @Expect(items[0].id, "main-tool-call-restore-1")
        @Expect(items[0].title, "Run cargo test")
        @Expect(items[0].state, "completed")
        @Expect(items[0].toolName, "bash")
        @Expect(items[0].toolCallId, "call-restore-1")
        @Expect(items[0].toolArguments.contains("cargo test"))
        @Expect(items[0].toolOutput, "tests passed")
    }

    @TestCase
    func orphanToolResultRestoresAsOneBoundedFallbackCard(): Unit {
        let items = tuiTranscriptItems(
            [
                ModelMessage(
                    ModelRole.User,
                    [
                        ModelBlock(
                            ModelBlockKind.ToolResult,
                            text: "legacy result",
                            callId: "legacy-call",
                            name: "bash"
                        )
                    ]
                )
            ],
            "main"
        )

        @Expect(items.size, 1)
        @Expect(items[0].id, "main-tool-legacy-call")
        @Expect(items[0].toolName, "bash")
        @Expect(items[0].toolOutput, "legacy result")
    }

    @TestCase
    func approvalSessionGrantLabelShowsExactScope(): Unit {
        @Expect(
            tuiApprovalGrantLabel(
                ApprovalGrantScope("temp.write", pathPrefix: "/tmp/cube_lib", toolName: "write")
            ),
            "Allow writes under /tmp/cube_lib for this session"
        )
        @Expect(
            tuiApprovalGrantLabel(ApprovalGrantScope("network", host: "api.example.test", toolName: "http")),
            "Allow network to api.example.test for this session"
        )
    }
}

@Test
class JsonStreamRedactionTests {
    @TestCase
    func secretsSplitAcrossTypedDeltasNeverReachJsonProjection(): Unit {
        let values = ArrayList<AgentEvent>()
        let stream = ApplicationJsonEventStream({ event => values.add(event) })
        let run = RunId("json-redaction-run")
        let trace = TraceId("json-redaction-trace")
        stream.accept(AgentEvent(
            EventMeta(1, trace, run),
            AgentEventPayload.TextDelta("prefix sk-app-SPLIT")
        ))
        @Expect(values.size, 0)
        stream.accept(AgentEvent(
            EventMeta(2, trace, run),
            AgentEventPayload.TextDelta("-PRIVATE-VALUE suffix\nAuthorization: Bear")
        ))
        stream.accept(AgentEvent(
            EventMeta(3, trace, run),
            AgentEventPayload.TextDelta("er APP-HEADER-SECRET\nvisible-app-text\n")
        ))
        stream.accept(AgentEvent(
            EventMeta(4, trace, run),
            AgentEventPayload.TextDelta(
                "-----BEGIN PRIVATE KEY-----\nAPP-PEM-"
            )
        ))
        stream.accept(AgentEvent(
            EventMeta(5, trace, run),
            AgentEventPayload.TextDelta(
                "PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
            )
        ))
        stream.accept(AgentEvent(
            EventMeta(6, trace, run),
            AgentEventPayload.TurnCompleted(TurnId("json-redaction-turn"))
        ))
        stream.finish()
        var output = ""
        for (event in values) {
            output += encodeAgentValue(applicationJsonEventValue(event)) + "\n"
        }
        @Expect(output.contains("\"code\":\"model.text_delta\""))
        @Expect(output.contains("\"code\":\"turn.completed\""))
        @Expect(output.contains("[REDACTED]"))
        @Expect(output.contains("visible-app-text"))
        @Expect(!output.contains("SPLIT-PRIVATE-VALUE"))
        @Expect(!output.contains("APP-HEADER-SECRET"))
        @Expect(!output.contains("APP-PEM-PRIVATE-BODY"))
    }
}

@Test
class ProductTuiBackendPlanReviewTests {
    @TestCase
    func consumedReviewClosesOverOriginalExecutionFailure(): Unit {
        appPlanReviewTest205({ product, _, backend, failures =>
            appEnqueuePlanReviewContract205(product)
            let events = ArrayList<TuiAgentEvent>()
            let sink: TuiAgentEventSink = { event => events.add(event) }
            failures.bind205(sink)
            let route = appPlanViewRoute205(backend.submit("/plan fixture plan write", sink), stage: "record", observed: events.toArray())
            let source = "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                "# Verification\n\nPreserve the first execution error."
            let (first, editedPrimary) = appPlanViewMetadata205(backend, route, editBody: Some(source))
            let firstId = first.field("view_id").getOrThrow().text
            let save = appPlanViewConfirmation205(backend.pluginViewAction(firstId, "1", "save",
                [TuiPluginViewField("plan", editedPrimary), TuiPluginViewField("feedback", "")], sink))
            let saved = backend.confirmPluginView(firstId, "2", save.field("request_digest").getOrThrow().text, true, sink)
            let updated = appPlanViewMetadata205(backend, appPlanViewRoute205(saved, stage: "save", observed: events.toArray()), expectedSource: Some(source),
                expectedWorkspace: product.workspace.rootPath())[0]
            let id = updated.field("view_id").getOrThrow().text
            @Expect(id != firstId)
            events.clear()
            let _ = backend.pluginViewAction(firstId, "1", "approve_fresh",
                [TuiPluginViewField("plan", editedPrimary), TuiPluginViewField("feedback", "")], sink)
            @Expect(events.any { event => match (event) {
                case TuiAgentEvent.Error(value) => value.contains("view.stale_event")
                case _ => false } })
            @Expect(backend.currentWorkMode(), "plan")
            let confirmation = appPlanViewConfirmation205(backend.pluginViewAction(id, "1", "approve_fresh",
                [TuiPluginViewField("plan", editedPrimary), TuiPluginViewField("feedback", "")], sink))
            events.clear()
            let previousSession = backend.currentSession()
            let failed = backend.confirmPluginView(id, "2", confirmation.field("request_digest").getOrThrow().text, true, sink)
            var errorCount: Int64 = 0
            var originalError = ""
            var closedIndex: Int64 = -1
            var errorIndex: Int64 = -1
            for (index in 0..events.size) {
                match (events[index]) {
                    case TuiAgentEvent.Error(value) =>
                        errorCount++; originalError = value; errorIndex = index
                    case TuiAgentEvent.PluginViewClosed(closedId, _) =>
                        if (closedId == id) { closedIndex = index }
                    case _ => ()
                }
            }
            @Expect(match (failed.action) { case TuiTurnAction.NoAction => true; case _ => false })
            @Expect(errorCount, 1)
            @Expect(closedIndex >= 0)
            @Expect(errorIndex > closedIndex)
            @Expect(originalError.contains("fixture.plan_execution_failed"))
            @Expect(!originalError.contains("application.plan_mode_inactive"))
            @Expect(backend.currentWorkMode(), "none")
            @Expect(backend.currentSession() != previousSession)
            let failedSession = backend.currentSession()
            events.clear()
            let _ = backend.confirmPluginView(id, "2", confirmation.field("request_digest").getOrThrow().text, true, sink)
            @Expect(events.any { event => match (event) {
                case TuiAgentEvent.Error(value) => value.contains("view.closed")
                case _ => false } })
            @Expect(backend.currentSession(), failedSession)
            @Expect(backend.currentWorkMode(), "none")
        })
    }

    @TestCase
    func consumedKeepFailureDoesNotDrainOrReplaceQueuedInput(): Unit {
        appPlanReviewTest205({ product, session, backend, failures =>
            appEnqueuePlanReviewContract205(product)
            let setupEvents = ArrayList<TuiAgentEvent>()
            let sink: TuiAgentEventSink = { event => setupEvents.add(event) }
            failures.bind205(sink)
            let route = appPlanViewRoute205(backend.submit("/plan fixture plan write", sink),
                stage: "record", observed: setupEvents.toArray())
            let source = "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                "# Verification\n\nDo not replace this error with queued work."
            let (first, editedPrimary) = appPlanViewMetadata205(backend, route, editBody: Some(source))
            let firstId = first.field("view_id").getOrThrow().text
            let save = appPlanViewConfirmation205(backend.pluginViewAction(firstId, "1", "save",
                [TuiPluginViewField("plan", editedPrimary), TuiPluginViewField("feedback", "")], sink))
            let saved = backend.confirmPluginView(firstId, "2", save.field("request_digest").getOrThrow().text, true, sink)
            let updated = appPlanViewMetadata205(backend, appPlanViewRoute205(saved, stage: "save", observed: setupEvents.toArray()), expectedSource: Some(source),
                expectedWorkspace: product.workspace.rootPath())[0]
            let id = updated.field("view_id").getOrThrow().text
            let confirmation = appPlanViewConfirmation205(backend.pluginViewAction(id, "1", "approve_keep",
                [TuiPluginViewField("plan", editedPrimary), TuiPluginViewField("feedback", "")], sink))
            @Assert(session.enqueue("plan-review-test", "follow_up", "queued input must remain pending").isOk())
            let previousSession = backend.currentSession()
            let events = ArrayList<TuiAgentEvent>()
            let failureSink: TuiAgentEventSink = { event => events.add(event) }
            failures.bind205(failureSink)
            let failed = backend.confirmPluginView(id, "2", confirmation.field("request_digest").getOrThrow().text, true,
                failureSink)
            @Expect(match (failed.action) { case TuiTurnAction.NoAction => true; case _ => false })
            @Expect(events.any { event => match (event) {
                case TuiAgentEvent.Error(value) => value.contains("fixture.plan_execution_failed")
                case _ => false } })
            @Expect(backend.currentSession(), previousSession)
            @Expect(session.queuedCount(), 1)
        })
    }
}

// The real review catalog intentionally contains only installed tools. This
// explicit model fixture proposes an existing controlled read-only action;
// approval later exercises the original provider failure before any dispatch.
func appEnqueuePlanReviewContract205(product: ProductRuntime): Unit {
    let root = product.workspace.rootPath()
    let arguments = objectValue([ValueField("executable", textValue("/bin/true")),
        ValueField("argv", listValue([])), ValueField("cwd", textValue(root)),
        ValueField("timeout", integerValue(30)), ValueField("readonly_workspace", boolValue(true)),
        ValueField("network", objectValue([ValueField("mode", textValue("denied"))]))])
    let contract = PlanContract([root], [PlanExecutionStep(PlanStepId("frontend-verify"), [], true,
        [PlanAction("frontend-readonly", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly,
            arguments, 1, exactArguments: true)])])
    product.fixtureProbe.getOrThrow().enqueueToolCallReply("frontend-review-plan", "plugin.axyndra:workflow.plan_write",
        objectValue([ValueField("content", textValue("Goal: review failure handling. Constraints: read-only. " +
            "Approach: controlled offline verification. Acceptance: preserve the original execution failure. Unresolved: none.")),
            ValueField("contract", planContractValue(contract))]))
}

func appPlanReviewTest205(run: (ProductRuntime, ApplicationSession, ProductTuiBackend, AppPlanFailureOutput205) -> Unit): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    let paid = LogicalJsonOwnerBudget(maximumCharged: 150994944).acquire(2097152)
    // This test frontend's actual DATA root outlives the complete producer,
    // decoded metadata, callbacks and helper. No public Raw export is refunded.
    try { appPlanReviewWholeHelper205(root, paid, run) }
    finally { paid.close(); let _ = removeIfExists(root, recursive: true) }
}

func appPlanReviewWholeHelper205(root: String, paid: LogicalJsonOwnerReservation,
    run: (ProductRuntime, ApplicationSession, ProductTuiBackend, AppPlanFailureOutput205) -> Unit): Unit {
    let workspace = root + "/workspace"
    Directory.create(workspace, recursive: true)
    let product = openProduct(config: ProductConfig(stateRoot: root + "/state", settingsRoot: root + "/settings",
        workspaceRoot: workspace, fixture: true, asyncEnabled: false)).value().getOrThrow()
    try {
        installAppPlanWorkflowFixture(product)
        let session = product.applicationSession()
        let backend = ProductTuiBackend(product, applicationSession: session,
            ownerAllocation180: Some({ bytes =>
                let source = paid.deriveRetainedLease(); source.ensureRetainedPeak(bytes); source }))
        backend.initializeFrontend180()
        let failures = AppPlanFailureOutput205()
        backend.observeOwnedFailureDisplay113(failures)
        var caseReturned = false
        try {
            appPlanReviewCaseFrame205(product, session, backend, failures, run)
            caseReturned = true
        } finally {
            // An exceptional backend call may still retain its own sink.
            // Only the normal complete scenario proves those turns finished.
            if (caseReturned) { failures.returnAfterWholeCase205() }
        }
    } finally { product.close().value().getOrThrow() }
}

// The real frontend consumes the independently paid failure display. The
// original queue acknowledges only after this complete callback returns.
class AppPlanFailureOutput205 <: OwnedTuiFailureDisplayOutput113 {
    private var sink: ?TuiAgentEventSink = None<TuiAgentEventSink>
    private let copies = ArrayList<OwnedTuiFailureDisplay113>()
    func bind205(sink: TuiAgentEventSink): Unit { this.sink = Some(sink) }
    public func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit> {
        copies.add(display)
        display.withCopiedFailure113({ code, message, _ =>
            let bytes = code.size + message.size
            if (bytes > (134217728 - 65536) / 64) { throw IllegalStateException("frontend failure copy exceeds its original bound") }
            match (display.ensureCopiedDisplayRetainedPeak(display.projectionInvoice + bytes * 64 + 65536)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
            let copied = String.fromUtf8(message.toArray()) + " (" + String.fromUtf8(code.toArray()) + ")"
            sink.getOrThrow()(TuiAgentEvent.Error(copied))
            Result<Unit>.Ok(())
        })
    }
    private func detachAfterCaseFrame205(): Array<OwnedTuiFailureDisplay113> {
        // The complete scenario helper has returned: drop its last sink/event
        // closure before retiring any independently paid event-copy backing.
        sink = None<TuiAgentEventSink>
        let returned = copies.toArray(); copies.clear(); returned
    }
    func returnAfterWholeCase205(): Unit {
        let returned = detachAfterCaseFrame205()
        for (display in returned) { display.closeUnpublishedCopiedFailure113().value().getOrThrow() }
    }
}
func appPlanReviewCaseFrame205(product: ProductRuntime, session: ApplicationSession,
    backend: ProductTuiBackend, failures: AppPlanFailureOutput205,
    run: (ProductRuntime, ApplicationSession, ProductTuiBackend, AppPlanFailureOutput205) -> Unit): Unit {
    run(product, session, backend, failures)
}

func appPlanViewRoute205(result: TuiTurnResult, stage!: String, observed!: Array<TuiAgentEvent>): String {
    match (result.action) {
        case TuiTurnAction.OpenPluginView(route) => route
        case _ =>
            var code = "no_direct_error"
            for (event in observed) {
                match (event) {
                    case TuiAgentEvent.Error(value) =>
                        code = "unclassified_error"
                        for (known in ["view.source_changed", "view.fields_limit", "plan.review_copy_capacity",
                            "plan.tool_unavailable", "plan.contract_invalid", "workflow.plan_tool_missing",
                            "application.owned_failure_pending", "fixture.plan_execution_failed"]) {
                            if (value.contains("(" + known + ")")) { code = known }
                        }
                    case _ => ()
                }
            }
            throw IllegalStateException("actual plan completion did not open its declared View; stage=" +
                stage + "; code=" + code + "; fixed_error_status=" + (result.status == "error").toString())
    }
}

func appPlanViewMetadata205(backend: ProductTuiBackend, route: String, expectedSource!: ?String = None,
    expectedWorkspace!: String = "", editBody!: ?String = None): (AgentValue, String) {
    let document = match (backend.loadPluginView(route).action) {
        case TuiTurnAction.PluginViewLoaded(value) => value
        case _ => throw IllegalStateException("actual installed View query failed")
    }
    try {
        let copied = document.withPresentation<(String, String)>({ metadata, _, primary =>
            match (expectedSource) {
                case Some(source) =>
                    let open = "\n\n<plan-contract>\n"
                    let close = "\n</plan-contract>"
                    @Assert(primary.startsWith(source + "\n\n<plan-review-checks>\n[]\n</plan-review-checks>" + open))
                    @Assert(primary.endsWith(close))
                    let offset = primary.indexOf(open).getOrThrow() + open.size
                    let parsed = parsePlanContract(parseUnifiedJson(primary[offset..primary.size - close.size]))
                    @Assert(parsed.isOk())
                    let contract = parsed.value().getOrThrow()
                    @Assert(contract.targetRoots.size == 1)
                    @Expect(contract.targetRoots[0], expectedWorkspace)
                    @Assert(contract.steps.size == 1)
                    @Expect(contract.steps[0].id.value, "frontend-verify")
                    @Assert(contract.steps[0].actions.size == 1)
                    let action = contract.steps[0].actions[0]
                    @Expect(action.id, "frontend-readonly")
                    @Assert(action.toolNames.size == 1)
                    @Expect(action.toolNames[0], "command_probe")
                    @Expect(action.effectCeiling, OperationEffectClass.ReadOnly)
                    @Expect(action.maxAttempts, 1)
                    @Expect(action.exactArguments)
                    @Expect(action.argumentConstraints.field("executable").getOrThrow().text, "/bin/true")
                    @Expect(action.argumentConstraints.field("cwd").getOrThrow().text, expectedWorkspace)
                    @Expect(action.argumentConstraints.field("readonly_workspace").getOrThrow().asBool())
                    @Expect(action.toolIdentities.field("command_probe").isSome())
                case None => ()
            }
            let edited = match (editBody) {
                case Some(body) =>
                    let marker = primary.indexOf("\n\n<plan-review-checks>\n").getOrThrow()
                    // The actual frontend edits the complete displayed source,
                    // preserving this View's reviewed contract and check bytes.
                    body + primary[marker..]
                case None => ""
            }
            (String.fromUtf8(metadata.toArray()), String.fromUtf8(edited.toArray()))
        })
        (decodeAgentValue(copied[0], maxBytes: 4096).value().getOrThrow(), copied[1])
    } finally { document.close() }
}

func appPlanViewConfirmation205(result: TuiTurnResult): AgentValue {
    let encoded = match (result.action) {
        case TuiTurnAction.ConfirmPluginView(value) => String.fromUtf8(value.toArray())
        case _ => throw IllegalStateException("actual declared action did not request Host confirmation")
    }
    decodeAgentValue(encoded, maxBytes: 4096).value().getOrThrow()
}


// Explicit test-only installation of the same actual operator-selected native
// contribution. This helper creates no Source, grant, ModelDecision or Receipt.
func installAppPlanWorkflowFixture(product: ProductRuntime): Unit {
    let record=match(product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow())){
        case PluginRegistryResult.Ok(value)=>value;case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    try { appInstallPlanWorkflowScoped205(product, record) }
    finally { record.close() }
}
