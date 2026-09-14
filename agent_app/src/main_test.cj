package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_tui.*
import tool_runtime.*
import model_adapters.*
import std.collection.*
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
        if (!exists(Path("target"))) {
            Directory.create("target", recursive: true)
        }
        let root = Directory.createTemp("target").toString()
        try {
            let workspace = root + "/workspace"
            Directory.create(workspace, recursive: true)
            let product = openProduct(
                config: ProductConfig(
                    stateRoot: root + "/state",
                    workspaceRoot: workspace,
                    fixture: true,
                    asyncEnabled: false
                )
            ).value().getOrThrow()
            let backend = ProductTuiBackend(product)
            let events = ArrayList<TuiAgentEvent>()
            let sink: TuiAgentEventSink = {event => events.add(event)}
            let opened = backend.submit("/plan fixture plan write", sink)
            let openedBody = match (opened.action) {
                case TuiTurnAction.OpenPlanReview(body) => body
                case _ => ""
            }
            @Assert(openedBody != "")
            let markerBody = "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                "# Verification\n\nPreserve the first execution error."
            let updated = backend.reviewPlan(
                planContentHash(openedBody),
                TuiPlanReviewDecision.UpdatePlan,
                markerBody,
                sink
            )
            let updatedBody = match (updated.action) {
                case TuiTurnAction.OpenPlanReview(body) => body
                case _ => ""
            }
            @Assert(updatedBody != "")
            let refreshed = backend.reviewPlan(
                planContentHash(openedBody),
                TuiPlanReviewDecision.ApproveFresh,
                "",
                sink
            )
            @Expect(match ((refreshed.planReviewDisposition, refreshed.action)) {
                case (TuiPlanReviewDisposition.Retain, TuiTurnAction.OpenPlanReview(body)) => body == updatedBody
                case _ => false
            })
            @Expect(backend.currentWorkMode(), "plan")
            events.clear()
            let previousSession = backend.currentSession()
            let failed = backend.reviewPlan(
                planContentHash(updatedBody),
                TuiPlanReviewDecision.ApproveFresh,
                "",
                sink
            )
            var errorCount: Int64 = 0
            var originalError = ""
            var consumedIndex: Int64 = -1
            var errorIndex: Int64 = -1
            for (index in 0..events.size) {
                let event = events[index]
                match (event) {
                    case TuiAgentEvent.Error(value) =>
                        errorCount += 1
                        originalError = value
                        errorIndex = index
                    case TuiAgentEvent.PlanReviewConsumed(hash) =>
                        if (hash == planContentHash(updatedBody)) {
                            consumedIndex = index
                        }
                    case _ => ()
                }
            }
            @Expect(match (failed.planReviewDisposition) {
                case TuiPlanReviewDisposition.Consumed => true
                case _ => false
            })
            @Expect(match (failed.action) {
                case TuiTurnAction.NoAction => true
                case _ => false
            })
            @Expect(failed.status, "error: fixture approved-plan execution failed")
            @Expect(errorCount, 1)
            @Expect(consumedIndex >= 0)
            @Expect(errorIndex > consumedIndex)
            @Expect(originalError.contains("fixture.plan_execution_failed"))
            @Expect(originalError.contains("fixture approved-plan execution failed"))
            @Expect(!originalError.contains("Plan mode is not active"))
            @Expect(backend.currentWorkMode(), "none")
            @Expect(backend.currentSession() != previousSession)
            let staleReview = backend.reviewPlan(
                planContentHash(updatedBody),
                TuiPlanReviewDecision.ApproveFresh,
                "",
                sink
            )
            @Expect(match (staleReview.planReviewDisposition) {
                case TuiPlanReviewDisposition.Consumed => true
                case _ => false
            })
            @Expect(match (staleReview.action) {
                case TuiTurnAction.NoAction => true
                case _ => false
            })
            @Expect(staleReview.status, "plan review failed: Plan mode is not active.")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func consumedKeepFailureDoesNotDrainOrReplaceQueuedInput(): Unit {
        if (!exists(Path("target"))) {
            Directory.create("target", recursive: true)
        }
        let root = Directory.createTemp("target").toString()
        try {
            let workspace = root + "/workspace"
            Directory.create(workspace, recursive: true)
            let product = openProduct(
                config: ProductConfig(
                    stateRoot: root + "/state",
                    workspaceRoot: workspace,
                    fixture: true,
                    asyncEnabled: false
                )
            ).value().getOrThrow()
            let applicationSession = product.applicationSession()
            let backend = ProductTuiBackend(product, applicationSession: applicationSession)
            let sink: TuiAgentEventSink = {_ => ()}
            let opened = backend.submit("/plan fixture plan write", sink)
            let openedBody = match (opened.action) {
                case TuiTurnAction.OpenPlanReview(body) => body
                case _ => ""
            }
            @Assert(openedBody != "")
            let updated = backend.reviewPlan(
                planContentHash(openedBody),
                TuiPlanReviewDecision.UpdatePlan,
                "# Goal\n\nFIXTURE-APPROVED-PLAN-EXECUTION-FAILURE\n\n" +
                    "# Verification\n\nDo not replace this error with queued work.",
                sink
            )
            let updatedBody = match (updated.action) {
                case TuiTurnAction.OpenPlanReview(body) => body
                case _ => ""
            }
            @Assert(updatedBody != "")
            @Assert(applicationSession.enqueue(
                "plan-review-test",
                "follow_up",
                "queued input must remain pending"
            ).isOk())
            let previousSession = backend.currentSession()

            let failed = backend.reviewPlan(
                planContentHash(updatedBody),
                TuiPlanReviewDecision.ApproveKeep,
                "",
                sink
            )

            @Expect(match ((failed.planReviewDisposition, failed.action)) {
                case (TuiPlanReviewDisposition.Consumed, TuiTurnAction.NoAction) => true
                case _ => false
            })
            @Expect(failed.status, "error: fixture approved-plan execution failed")
            @Expect(backend.currentSession(), previousSession)
            @Expect(applicationSession.queuedCount(), 1)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func inactiveFailureInvalidatesRatherThanRetainsReview(): Unit {
        @Expect(match (planReviewFailureDisposition(
            AgentError(
                AgentErrorKind.Conflict,
                "application.plan_mode_inactive",
                "Plan mode is not active."
            )
        )) {
            case TuiPlanReviewDisposition.Consumed => true
            case _ => false
        })
        @Expect(match (planReviewFailureDisposition(
            AgentError(
                AgentErrorKind.Conflict,
                "application.plan_changed",
                "plan changed"
            )
        )) {
            case TuiPlanReviewDisposition.Retain => true
            case _ => false
        })
    }
}

@Test
class ProductTuiBackendMcpStatusTests {
    @TestCase
    func mcpStatusReflectsClosedServerAfterBackendConstruction(): Unit {
        if (!exists(Path("target"))) {
            Directory.create("target", recursive: true)
        }
        let root = Directory.createTemp("target").toString()
        try {
            let settings = root + "/settings"
            let workspace = root + "/workspace"
            Directory.create(settings, recursive: true)
            Directory.create(workspace, recursive: true)
            File.writeTo(
                settings + "/config.yml",
                "default_model: local/product-contract\nasync:\n  enabled: false\n".toArray()
            )
            File.writeTo(
                settings + "/models.yml",
                ("models:\n" +
                    "  - id: product-contract\n" +
                    "    provider: local\n" +
                    "    context_window: 200000\n" +
                    "    max_output_tokens: 8192\n" +
                    "    thinking:\n" +
                    "      mode: none\n").toArray()
            )
            File.writeTo(
                settings + "/providers.yml",
                ("providers:\n" +
                    "  - id: local\n" +
                    "    provider: custom\n" +
                    "    protocol: completions\n" +
                    "    dialect: generic_chat\n" +
                    "    base_url: http://127.0.0.1:11434\n" +
                    "    api_key_env: MCP_PRODUCT_UNUSED_PROVIDER_KEY\n").toArray()
            )
            let fixtureScript = workspace + "/mcp_fixture.py"
            File.writeTo(
                fixtureScript,
                ("import json\n" +
                    "import sys\n" +
                    "\n" +
                    "for line in sys.stdin:\n" +
                    "    request = json.loads(line)\n" +
                    "    request_id = request.get(\"id\")\n" +
                    "    if request_id is None:\n" +
                    "        continue\n" +
                    "    method = request.get(\"method\", \"\")\n" +
                    "    if method == \"server/discover\":\n" +
                    "        result = {\"supportedVersions\": [\"2026-07-28\"], \"capabilities\": {\"tools\": {\"listChanged\": False}}, \"ttlMs\": 0, \"cacheScope\": \"private\"}\n" +
                    "    elif method == \"tools/list\":\n" +
                    "        result = {\"tools\": [], \"ttlMs\": 0, \"cacheScope\": \"private\"}\n" +
                    "    else:\n" +
                    "        result = {}\n" +
                    "    result[\"resultType\"] = \"complete\"\n" +
                    "    result[\"_meta\"] = {\"io.modelcontextprotocol/serverInfo\": {\"name\": \"status-fixture\", \"version\": \"1.0.0\"}}\n" +
                    "    response = {\"jsonrpc\": \"2.0\", \"id\": request_id, \"result\": result}\n" +
                    "    sys.stdout.write(json.dumps(response, separators=(\",\", \":\")) + \"\\n\")\n" +
                    "    sys.stdout.flush()\n").toArray()
            )
            File.writeTo(
                settings + "/mcp.yml",
                ("version: 1\n" +
                    "servers:\n" +
                    "  - id: refresh\n" +
                    "    enabled: true\n" +
                    "    transport: stdio\n" +
                    "    command: /usr/bin/python3\n" +
                    "    args:\n" +
                    "      - \"-B\"\n" +
                    "      - \"-u\"\n" +
                    "      - \"" + fixtureScript + "\"\n" +
                    "    max_frame_bytes: 65536\n" +
                    "    request_timeout_ms: 1000\n" +
                    "    graceful_shutdown_ms: 1000\n").toArray()
            )
            let product = openProduct(config: ProductConfig(
                settingsRoot: settings,
                stateRoot: root + "/state",
                workspaceRoot: workspace,
                approvalMode: ApprovalMode.Yolo,
                asyncEnabled: false
            )).value().getOrThrow()
            try {
                let backend = ProductTuiBackend(product)
                @Expect(backend.mcpStatus().text.contains("[ready] refresh"))
                @Expect(product.closeMcp().isOk())
                @Expect(backend.mcpStatus().text.contains("[stopped] refresh"))
            } finally {
                let _ = product.closeMcp()
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
