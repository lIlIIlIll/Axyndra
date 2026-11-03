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
        appPlanReviewTest205({ _, _, backend =>
            let events = ArrayList<TuiAgentEvent>()
            let sink: TuiAgentEventSink = { event => events.add(event) }
            let route = appPlanViewRoute205(backend.submit("/plan fixture plan write", sink))
            let first = appPlanViewMetadata205(backend, route)
            let firstId = first.field("view_id").getOrThrow().text
            let source = "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                "# Verification\n\nPreserve the first execution error."
            let save = appPlanViewConfirmation205(backend.pluginViewAction(firstId, "1", "save",
                [TuiPluginViewField("plan", source), TuiPluginViewField("feedback", "")], sink))
            let saved = backend.confirmPluginView(firstId, "2", save.field("request_digest").getOrThrow().text, true, sink)
            let updated = appPlanViewMetadata205(backend, appPlanViewRoute205(saved), expectedSource: Some(source))
            let id = updated.field("view_id").getOrThrow().text
            @Expect(id != firstId)
            events.clear()
            let _ = backend.pluginViewAction(firstId, "1", "approve_fresh",
                [TuiPluginViewField("plan", source), TuiPluginViewField("feedback", "")], sink)
            @Expect(events.any { event => match (event) {
                case TuiAgentEvent.Error(value) => value.contains("view.stale_event")
                case _ => false } })
            @Expect(backend.currentWorkMode(), "plan")
            let confirmation = appPlanViewConfirmation205(backend.pluginViewAction(id, "1", "approve_fresh",
                [TuiPluginViewField("plan", source), TuiPluginViewField("feedback", "")], sink))
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
        appPlanReviewTest205({ _, session, backend =>
            let sink: TuiAgentEventSink = { _ => () }
            let route = appPlanViewRoute205(backend.submit("/plan fixture plan write", sink))
            let first = appPlanViewMetadata205(backend, route)
            let firstId = first.field("view_id").getOrThrow().text
            let source = "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                "# Verification\n\nDo not replace this error with queued work."
            let save = appPlanViewConfirmation205(backend.pluginViewAction(firstId, "1", "save",
                [TuiPluginViewField("plan", source), TuiPluginViewField("feedback", "")], sink))
            let saved = backend.confirmPluginView(firstId, "2", save.field("request_digest").getOrThrow().text, true, sink)
            let updated = appPlanViewMetadata205(backend, appPlanViewRoute205(saved), expectedSource: Some(source))
            let id = updated.field("view_id").getOrThrow().text
            let confirmation = appPlanViewConfirmation205(backend.pluginViewAction(id, "1", "approve_keep",
                [TuiPluginViewField("plan", source), TuiPluginViewField("feedback", "")], sink))
            @Assert(session.enqueue("plan-review-test", "follow_up", "queued input must remain pending").isOk())
            let previousSession = backend.currentSession()
            let events = ArrayList<TuiAgentEvent>()
            let failed = backend.confirmPluginView(id, "2", confirmation.field("request_digest").getOrThrow().text, true,
                { event => events.add(event) })
            @Expect(match (failed.action) { case TuiTurnAction.NoAction => true; case _ => false })
            @Expect(events.any { event => match (event) {
                case TuiAgentEvent.Error(value) => value.contains("fixture.plan_execution_failed")
                case _ => false } })
            @Expect(backend.currentSession(), previousSession)
            @Expect(session.queuedCount(), 1)
        })
    }
}

func appPlanReviewTest205(run: (ProductRuntime, ApplicationSession, ProductTuiBackend) -> Unit): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    let paid = LogicalJsonOwnerBudget(maximumCharged: 150994944).acquire(2097152)
    // This test frontend's actual DATA root outlives the complete producer,
    // decoded metadata, callbacks and helper. No public Raw export is refunded.
    try { appPlanReviewWholeHelper205(root, paid, run) }
    finally { paid.close(); let _ = removeIfExists(root, recursive: true) }
}

func appPlanReviewWholeHelper205(root: String, paid: LogicalJsonOwnerReservation,
    run: (ProductRuntime, ApplicationSession, ProductTuiBackend) -> Unit): Unit {
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
        run(product, session, backend)
    } finally { product.close().value().getOrThrow() }
}

func appPlanViewRoute205(result: TuiTurnResult): String {
    match (result.action) {
        case TuiTurnAction.OpenPluginView(route) => route
        case _ => throw IllegalStateException("actual plan completion did not open its declared View")
    }
}

func appPlanViewMetadata205(backend: ProductTuiBackend, route: String, expectedSource!: ?String = None): AgentValue {
    let document = match (backend.loadPluginView(route).action) {
        case TuiTurnAction.PluginViewLoaded(value) => value
        case _ => throw IllegalStateException("actual installed View query failed")
    }
    try {
        let copied = document.withPresentation<String>({ metadata, _, primary =>
            match (expectedSource) { case Some(source) => @Expect(primary, source); case None => () }
            String.fromUtf8(metadata.toArray())
        })
        decodeAgentValue(copied, maxBytes: 4096).value().getOrThrow()
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
