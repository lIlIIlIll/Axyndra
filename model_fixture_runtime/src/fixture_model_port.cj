package model_fixture_runtime

import agent_domain as domain
import yjson.JsonNode
import yjson_support.*
import agent_ports as ports
import std.collection.*
import std.sync.*

// Product/debug fixture behavior is deliberately independent of provider wire
// codecs and transports. Extracted unchanged from model_adapters.
public class FixtureModelPort <: ports.ModelPort {
    private let failFirst: Bool
    private var calls: Int64 = 0
    // Last request's thinking level, for contract probes (e.g. plan mode
    // must force High even when the session default is lower).
    public var lastThinking: domain.ThinkingLevel = domain.ThinkingLevel.Medium
    // Fixture-only observation point for end-to-end Product request contracts.
    // Production transports never read or populate this field.
    public var lastRequest: ?domain.ModelRequest = None
    private let scriptedLock = Mutex()
    private let scriptedReplies = ArrayList<domain.ModelReply>()
    private var scriptedReplySequence: Int64 = 0

    public init(failFirst!: Bool = false) {
        this.failFirst = failFirst
    }

    // A fixture transcript describes this actual local provider, not a wire
    // protocol or dispatch grant. Reopening must reproduce its exact request,
    // fault/call state and ordered scripted input before Core may resume it.
    public func transcriptSnapshot(request: domain.ModelRequest): ?String {
        try { Some(recoverableFixtureSnapshot11318(request)) }
        catch (_: Exception) { None }
    }

    public func validateTranscriptSnapshot(snapshot: String): Bool {
        try {
            let value = parseUnifiedJson(snapshot, maxBytes: 67108864, maxDepth: 64)
            let requestId = value.field("request_id").getOrThrow()
            if (requestId.unifiedKind != UnifiedJsonKind.Text) { return false }
            let request = match (domain.modelRequestFromSnapshotValue(
                value.field("request").getOrThrow(), requestId.text)) {
                case domain.Result.Ok(value) => value
                case domain.Result.Err(_) => return false
            }
            // Rebuilding the whole envelope also rejects extra/missing fields
            // and altered scripts. Core independently checks persisted digests
            // and byte-exact regeneration against its canonical checkpoint.
            domain.canonicalAgentValuesEqual(value, parseUnifiedJson(
                recoverableFixtureSnapshot11318(request), maxBytes: 67108864, maxDepth: 64))
        } catch (_: Exception) { false }
    }

    private func recoverableFixtureSnapshot11318(request: domain.ModelRequest): String {
        scriptedLock.lock()
        try {
            let scripts = ArrayList<domain.AgentValue>()
            for (reply in scriptedReplies) {
                // enqueueToolCallReply is the only queue writer. Its original
                // terminal metadata is fixed; these are all variable inputs.
                scripts.add(domain.objectValue([
                    domain.ValueField("response_id", domain.textValue(reply.responseId)),
                    domain.ValueField("blocks", domain.modelRequestSnapshotValue(domain.ModelRequest(
                        "fixture-scripted-reply", [domain.ModelMessage(domain.ModelRole.Assistant, reply.blocks)])))
                ]))
            }
            let encoded = domain.objectValue([
                domain.ValueField("schema", domain.textValue("axyndra.fixture-model-transcript/v1")),
                domain.ValueField("adapter_version", domain.textValue("fixture-v1")),
                domain.ValueField("fail_first", domain.boolValue(failFirst)),
                domain.ValueField("calls", domain.integerValue(calls)),
                domain.ValueField("script_sequence", domain.integerValue(scriptedReplySequence)),
                domain.ValueField("scripts", domain.listValue(scripts.toArray())),
                domain.ValueField("request_id", domain.textValue(request.requestId)),
                domain.ValueField("request", domain.modelRequestSnapshotValue(request))
            ]).stringify()
            if (encoded.size > 67108864) {
                throw IllegalArgumentException("fixture transcript exceeds the original model protocol ceiling")
            }
            // Preserve the same strict duplicate/depth and 64-MiB input gate
            // used by the existing provider-neutral model snapshot codec.
            parseUnifiedJson(encoded, maxBytes: 67108864, maxDepth: 64).stringify()
        } finally { scriptedLock.unlock() }
    }

    // Fixture-only read observation; the original execute increment is unchanged.
    public func observedCallCount11318(): Int64 { calls }

    public func enqueueToolCallReply(
        callId: String,
        name: String,
        arguments: domain.AgentValue
    ): Unit {
        scriptedLock.lock()
        try {
            scriptedReplySequence += 1
            scriptedReplies.add(fixtureTerminalReply(
                [domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: callId,
                    name: name,
                    arguments: arguments
                )],
                stopReason: "tool_use",
                inputTokens: 1,
                outputTokens: 1,
                providerId: "fixture",
                responseId: "fixture-scripted-" + scriptedReplySequence.toString()
            ))
        } finally {
            scriptedLock.unlock()
        }
    }

    private func takeScriptedReply(): ?domain.ModelReply {
        scriptedLock.lock()
        try {
            if (scriptedReplies.isEmpty()) {
                None
            } else {
                Some(scriptedReplies.remove(at: 0))
            }
        } finally {
            scriptedLock.unlock()
        }
    }
    public func execute(
        request: domain.ModelRequest,
        events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        lastRequest = Some(request)
        lastThinking = request.thinking
        calls += 1
        if (failFirst && calls == 1) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Transport,
                    "fixture.transport",
                    "fixture transport failure",
                    retryable: true,
                    fallbackAllowed: true
                )
            )
        }
        match (takeScriptedReply()) {
            case Some(reply) => return domain.Result.Ok(reply)
            case None => ()
        }
        let lastText = if (request.messages.isEmpty()) {
            ""
        } else {
            messageText(request.messages[request.messages.size - 1])
        }
        if (lastText.startsWith("[plan-review approved ") &&
            lastText.contains("FIXTURE-APPROVED-PLAN-EXECUTION-FAILURE")) {
            return domain.Result.Err(
                domain.AgentError(
                    domain.AgentErrorKind.Transport,
                    "fixture.plan_execution_failed",
                    "fixture approved-plan execution failed",
                    retryable: false,
                    fallbackAllowed: false
                )
            )
        }
        if (request.system.contains("COMPACTION_SEMANTIC_SUMMARIZER")) {
            if (lastText.contains("FIXTURE-COMPACTION-SUMMARY-FAILURE")) {
                return domain.Result.Err(
                    domain.AgentError(
                        domain.AgentErrorKind.Transport,
                        "fixture.compaction_summary_failed",
                        "fixture compaction summarizer failed",
                        retryable: false,
                        fallbackAllowed: true
                    )
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.Text,
                            text: "The session established concrete facts and left clearly identified work for the next turn."
                        )
                    ],
                    stopReason: "end_turn",
                    inputTokens: request.messages.size,
                    outputTokens: 18,
                    providerId: "fixture",
                    responseId: "fixture-compaction-summary-" + calls.toString()
                )
            )
        }
        if (request.system.contains("INDEPENDENT_APPROVAL_REVIEWER")) {
            let normalized = lastText.toAsciiLower()
            let decision = if (normalized.contains("\"sensitive_data\"") || normalized.contains("\"system_change\"") ||
                normalized.contains("rm -rf /")) {
                "{\"decision\":\"deny\",\"reason\":\"The operation crosses a permanent safety boundary or exposes sensitive data.\",\"riskLevel\":\"critical\",\"approvedCapabilities\":[]}"
            } else if (normalized.contains("\"git_destructive\"") || normalized.contains("\"outside_workspace\"") ||
                normalized.contains("\"network\"")) {
                "{\"decision\":\"ask_user\",\"reason\":\"The operation has external or destructive side effects that require explicit user confirmation.\",\"riskLevel\":\"high\",\"approvedCapabilities\":[]}"
            } else {
                "{\"decision\":\"approve\",\"reason\":\"The scoped operation matches the user request and remains within the workspace.\",\"riskLevel\":\"low\",\"approvedCapabilities\":[\"workspace.write\"]}"
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [domain.ModelBlock(domain.ModelBlockKind.Text, text: decision)],
                    stopReason: "end_turn",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-approval-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture approval safe" || lastText == "fixture approval dangerous" || lastText ==
            "fixture approval ask" || lastText == "fixture approval execution failure") && hasTool(request.tools,
            if (lastText == "fixture approval safe" || lastText == "fixture approval execution failure") {
                "write"
            } else {
                "bash"
            })) {
            let block = if (lastText == "fixture approval safe" || lastText == "fixture approval execution failure") {
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: if (lastText == "fixture approval safe") {
                        "fixture-approval-safe"
                    } else {
                        "fixture-approval-execution-failure"
                    },
                    name: "write",
                    arguments: domain.objectValue(
                        [
                            domain.ValueField("path", domain.textValue(if (lastText == "fixture approval safe") {
                                "tmp/result.txt"
                            } else {
                                "../missing-parent/child.txt"
                            })),
                            domain.ValueField("content", domain.textValue("hello\n"))
                        ]
                    )
                )
            } else {
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: "fixture-approval-risk",
                    name: "bash",
                    arguments: domain.objectValue(
                        [domain.ValueField("command",
                            domain.textValue(if (lastText == "fixture approval dangerous") {
                                "rm -rf /"
                            } else {
                                "git push --force origin main"
                            }))])
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-approval-tool-" + calls.toString()
                )
            )
        }
        match (fixtureHubProcessBlock(lastText)) {
            case Some(block) =>
                if (hasTool(request.tools, block.name)) {
                    if (request.streaming) {
                        events(
                            domain.ModelEvent.ToolCallStarted(
                                block.callId,
                                block.name
                            )
                        )
                        events(domain.ModelEvent.ToolCallCompleted(block.callId))
                        events(domain.ModelEvent.Completed)
                    }
                    return domain.Result.Ok(
                        fixtureTerminalReply(
                            [block],
                            stopReason: "tool_use",
                            inputTokens: request.messages.size,
                            outputTokens: 1,
                            providerId: "fixture",
                            responseId: "fixture-" + calls.toString()
                        )
                    )
                }
            case None => ()
        }
        if (lastText == "fixture ask" && hasTool(request.tools, "ask")) {
            let block = domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "fixture-ask-call",
                name: "ask",
                arguments: domain.objectValue(
                    [
                        domain.ValueField(
                            "questions",
                            domain.listValue(
                                [
                                    domain.objectValue(
                                        [
                                            domain.ValueField("id", domain.textValue("features")),
                                            domain.ValueField(
                                                "question",
                                                domain.textValue("Which features should be enabled?")
                                            ),
                                            domain.ValueField(
                                                "options",
                                                domain.listValue(
                                                    [
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField("label", domain.textValue("Search")),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Fast workspace lookup")
                                                                )
                                                            ]
                                                        ),
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField("label", domain.textValue("Export")),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Portable reports")
                                                                ),
                                                                domain.ValueField(
                                                                    "preview",
                                                                    domain.textValue("HTML and JSON")
                                                                )
                                                            ]
                                                        )
                                                    ]
                                                )
                                            ),
                                            domain.ValueField("multi", domain.boolValue(true)),
                                            domain.ValueField("recommended", domain.integerValue(1))
                                        ]
                                    ),
                                    domain.objectValue(
                                        [
                                            domain.ValueField("id", domain.textValue("verification")),
                                            domain.ValueField(
                                                "question",
                                                domain.textValue("Which verification should run?")
                                            ),
                                            domain.ValueField(
                                                "options",
                                                domain.listValue(
                                                    [
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField(
                                                                    "label",
                                                                    domain.textValue("Node tests")
                                                                ),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Run the core engine contract")
                                                                )
                                                            ]
                                                        ),
                                                        domain.objectValue(
                                                            [
                                                                domain.ValueField(
                                                                    "label",
                                                                    domain.textValue("Manual only")
                                                                ),
                                                                domain.ValueField(
                                                                    "description",
                                                                    domain.textValue("Skip automated verification")
                                                                )
                                                            ]
                                                        )
                                                    ]
                                                )
                                            ),
                                            domain.ValueField("recommended", domain.integerValue(0))
                                        ]
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
            if (request.streaming) {
                events(domain.ModelEvent.ToolCallStarted(block.callId, "ask"))
                events(domain.ModelEvent.ToolCallCompleted(block.callId))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-ask"
                )
            )
        }
        var fixturePlanTool = ""
        for (tool in request.tools where tool.name == "plan_write" || tool.name == "plugin.axyndra:workflow.plan_write") {
            if (fixturePlanTool != "") { throw IllegalStateException("fixture plan catalogue is ambiguous") }
            fixturePlanTool = tool.name
        }
        if ((lastText == "fixture plan write" || lastText.startsWith("Plan mode protocol correction:")) && fixturePlanTool != "") {
            let block = domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "fixture-plan-call",
                name: fixturePlanTool,
                arguments: domain.objectValue(
                    [
                        domain.ValueField(
                            "content",
                            domain.textValue(
                                "Goal: ship a plan\nConstraints: read-only\n" +
                                    "Approach: inspect then write\nAcceptance: contract passes\n" + "Unresolved: none")
                        )
                    ]
                )
            )
            if (request.streaming) {
                events(domain.ModelEvent.ToolCallStarted(block.callId, fixturePlanTool))
                events(domain.ModelEvent.ToolCallCompleted(block.callId))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [block],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-plan"
                )
            )
        }
        if (lastText == "fixture task batch" && hasTool(request.tools, "plugin.axyndra:workflow.task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-batch-call",
                        "plugin.axyndra:workflow.task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-batch-call"))
                events(domain.ModelEvent.Completed)
            }
            let items = ArrayList<domain.AgentValue>()
            for (name in ["fixture-batch-a", "fixture-batch-b"]) {
                items.add(
                    domain.objectValue(
                        [
                            domain.ValueField(
                                "name",
                                domain.textValue(name)
                            ),
                            domain.ValueField(
                                "agent",
                                domain.textValue("reviewer")
                            ),
                            domain.ValueField(
                                "task",
                                domain.textValue("child fixture yield")
                            )
                        ]
                    )
                )
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-batch-call",
                            name: "plugin.axyndra:workflow.task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("shared fixture context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(items.toArray())
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture hub jobs" && hasTool(request.tools, "plugin.axyndra:workflow.hub_jobs")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-jobs-call",
                        "plugin.axyndra:workflow.hub_jobs"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-jobs-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-jobs-call",
                            name: "plugin.axyndra:workflow.hub_jobs",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("jobs")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture hub inbox" || lastText == "fixture hub list") && hasTool(request.tools, "plugin.axyndra:workflow.hub_peers")) {
            let op = if (lastText == "fixture hub inbox") {
                "inbox"
            } else {
                "list"
            }
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-" + op + "-call",
                        "plugin.axyndra:workflow.hub_peers"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-" + op + "-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-" + op + "-call",
                            name: "plugin.axyndra:workflow.hub_peers",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue(op)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture hub send child" && hasTool(request.tools, "plugin.axyndra:workflow.hub_messages")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-hub-send-child-call",
                        "plugin.axyndra:workflow.hub_messages"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-hub-send-child-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-hub-send-child-call",
                            name: "plugin.axyndra:workflow.hub_messages",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("send")
                                    ),
                                    domain.ValueField(
                                        "to",
                                        domain.textValue("fixture-hub-child")
                                    ),
                                    domain.ValueField(
                                        "message",
                                        domain.textValue("follow up child")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task write" && hasTool(request.tools, "plugin.axyndra:workflow.task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-write-call",
                        "plugin.axyndra:workflow.task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-write-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-write-call",
                            name: "plugin.axyndra:workflow.task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture write child context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-write-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("task")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture write")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task hub send" && hasTool(request.tools, "plugin.axyndra:workflow.task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-hub-call",
                        "plugin.axyndra:workflow.task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-hub-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-hub-call",
                            name: "plugin.axyndra:workflow.task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture hub child context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-hub-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("reviewer")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture hub send")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if ((lastText == "fixture async bash" || lastText == "fixture async bash wait") && hasTool(request.tools, "bash")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-async-bash-call",
                        "bash"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-async-bash-call"))
                events(domain.ModelEvent.Completed)
            }
            let command = if (lastText == "fixture async bash wait") {
                "sleep 5"
            } else {
                "printf async-bash-result"
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-async-bash-call",
                            name: "bash",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "command",
                                        domain.textValue(command)
                                    ),
                                    domain.ValueField(
                                        "async",
                                        domain.boolValue(true)
                                    ),
                                    domain.ValueField(
                                        "timeout",
                                        domain.integerValue(10)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task" && hasTool(request.tools, "plugin.axyndra:workflow.task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-call",
                        "plugin.axyndra:workflow.task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-call",
                            name: "plugin.axyndra:workflow.task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("single child fixture context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-child")
                                                        ),
                                                        domain.ValueField(
                                                            "agent",
                                                            domain.textValue("reviewer")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture yield")
                                                        ),
                                                        domain.ValueField(
                                                            "outputSchema",
                                                            domain.objectValue(
                                                                [
                                                                    domain.ValueField(
                                                                        "type",
                                                                        domain.textValue("object")
                                                                    ),
                                                                    domain.ValueField(
                                                                        "properties",
                                                                        domain.objectValue(
                                                                            [
                                                                                domain.ValueField(
                                                                                    "answer",
                                                                                    domain.objectValue(
                                                                                        [
                                                                                            domain.ValueField(
                                                                                                "type",
                                                                                                domain.textValue(
                                                                                                    "string")
                                                                                            )
                                                                                        ]
                                                                                    )
                                                                                )
                                                                            ]
                                                                        )
                                                                    ),
                                                                    domain.ValueField(
                                                                        "required",
                                                                        domain.listValue(
                                                                            [domain.textValue("answer")])
                                                                    )
                                                                ]
                                                            )
                                                        ),
                                                        domain.ValueField(
                                                            "schemaMode",
                                                            domain.textValue("strict")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture task cancel" && hasTool(request.tools, "plugin.axyndra:workflow.task")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-task-cancel-call",
                        "plugin.axyndra:workflow.task"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-task-cancel-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-task-cancel-call",
                            name: "plugin.axyndra:workflow.task",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "context",
                                        domain.textValue("fixture cancellation context")
                                    ),
                                    domain.ValueField(
                                        "tasks",
                                        domain.listValue(
                                            [
                                                domain.objectValue(
                                                    [
                                                        domain.ValueField(
                                                            "name",
                                                            domain.textValue("fixture-cancel-child")
                                                        ),
                                                        domain.ValueField(
                                                            "task",
                                                            domain.textValue("child fixture bash wait")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture yield" && hasTool(request.tools, "plugin.axyndra:workflow.yield")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-yield-call",
                        "plugin.axyndra:workflow.yield"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-yield-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-yield-call",
                            name: "plugin.axyndra:workflow.yield",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "result",
                                        domain.objectValue(
                                            [
                                                domain.ValueField(
                                                    "data",
                                                    domain.objectValue(
                                                        [
                                                            domain.ValueField(
                                                                "answer",
                                                                domain.textValue("reviewed")
                                                            )
                                                        ]
                                                    )
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture bash wait" && hasTool(request.tools, "bash")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-bash-wait",
                        "bash"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-bash-wait"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-bash-wait",
                            name: "bash",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "command",
                                        domain.textValue("sleep 5")
                                    ),
                                    domain.ValueField(
                                        "timeout",
                                        domain.integerValue(10000)
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture write" && hasTool(request.tools, "write")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-write",
                        "write"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-write"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-write",
                            name: "write",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("child-approved.txt")
                                    ),
                                    domain.ValueField(
                                        "content",
                                        domain.textValue("written by child\n")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "child fixture hub send" && hasTool(request.tools, "plugin.axyndra:workflow.hub_messages")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-child-hub-send",
                        "plugin.axyndra:workflow.hub_messages"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-child-hub-send"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-child-hub-send",
                            name: "plugin.axyndra:workflow.hub_messages",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("send")
                                    ),
                                    domain.ValueField(
                                        "to",
                                        domain.textValue("Main")
                                    ),
                                    domain.ValueField(
                                        "message",
                                        domain.textValue("child report delivered")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture vnext read" && hasTool(request.tools, "read")) {
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-vnext-read",
                            name: "read",
                            arguments: domain.objectValue([
                                domain.ValueField("path", domain.textValue("input.txt"))
                            ])
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-vnext-read-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host uri read" && hasTool(request.tools, "read")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-uri-read",
                        "read"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-uri-read"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-uri-read",
                            name: "read",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("hostdoc://guide")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host uri write" && hasTool(request.tools, "write")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-uri-write",
                        "write"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-uri-write"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-uri-write",
                            name: "write",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "path",
                                        domain.textValue("hostdoc://guide")
                                    ),
                                    domain.ValueField(
                                        "content",
                                        domain.textValue("updated by fixture")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "fixture host tool" && hasTool(request.tools, "host_echo")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-host-call",
                        "host_echo"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-host-call"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-host-call",
                            name: "host_echo",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "text",
                                        domain.textValue("from fixture")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        if (lastText == "Continue working on the active goal." && hasTool(request.tools, "goal")) {
            if (request.streaming) {
                events(
                    domain.ModelEvent.ToolCallStarted(
                        "fixture-goal-complete",
                        "goal"
                    )
                )
                events(domain.ModelEvent.ToolCallCompleted("fixture-goal-complete"))
                events(domain.ModelEvent.Completed)
            }
            return domain.Result.Ok(
                fixtureTerminalReply(
                    [
                        domain.ModelBlock(
                            domain.ModelBlockKind.ToolCall,
                            callId: "fixture-goal-complete",
                            name: "goal",
                            arguments: domain.objectValue(
                                [
                                    domain.ValueField(
                                        "op",
                                        domain.textValue("complete")
                                    )
                                ]
                            )
                        )
                    ],
                    stopReason: "tool_use",
                    inputTokens: request.messages.size,
                    outputTokens: 1,
                    providerId: "fixture",
                    responseId: "fixture-" + calls.toString()
                )
            )
        }
        let text = if (request.messages.size == 0) {
            "fixture response"
        } else if (lastText == "fixture split json secrets") {
            "prefix sk-app-SPLIT-PRIVATE-VALUE suffix\n" +
                "Authorization: Bearer APP-HEADER-SECRET\nvisible-app-text\n" +
                "-----BEGIN PRIVATE KEY-----\nAPP-PEM-PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
        } else {
            "fixture response for " + messageText(request.messages[request.messages.size - 1])
        }
        if (request.streaming) {
            if (lastText == "fixture split json secrets") {
                events(domain.ModelEvent.TextDelta("prefix sk-app-SPLIT"))
                events(domain.ModelEvent.TextDelta(
                    "-PRIVATE-VALUE suffix\nAuthorization: Bear"
                ))
                events(domain.ModelEvent.TextDelta(
                    "er APP-HEADER-SECRET\nvisible-app-text\n"
                ))
                events(domain.ModelEvent.TextDelta(
                    "-----BEGIN PRIVATE KEY-----\nAPP-PEM-"
                ))
                events(domain.ModelEvent.TextDelta(
                    "PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
                ))
            } else {
                events(domain.ModelEvent.TextDelta(text))
            }
            events(domain.ModelEvent.Completed)
        }
        domain.Result.Ok(
            fixtureTerminalReply(
                [domain.ModelBlock(domain.ModelBlockKind.Text, text: text)],
                stopReason: "end_turn",
                inputTokens: request.messages.size,
                outputTokens: 1,
                providerId: "fixture",
                responseId: "fixture-" + calls.toString()
            )
        )
    }
}

// Fixture responses still cross the same strict provider-terminal boundary as
// real adapters. Keeping the evidence here prevents tests and local product
// modes from reviving the removed "HTTP success implies complete" shortcut.
func fixtureTerminalReply(
    blocks: Array<domain.ModelBlock>,
    stopReason!: String = "end_turn",
    inputTokens!: Int64 = 0,
    outputTokens!: Int64 = 0,
    providerId!: String = "fixture",
    responseId!: String = ""
): domain.ModelReply {
    var hasTool = false
    var hasRefusal = false
    for (block in blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.ToolCall => hasTool = true
            case domain.ModelBlockKind.Refusal => hasRefusal = true
            case _ => ()
        }
    }
    domain.ModelReply(
        blocks,
        stopReason: stopReason,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        providerId: providerId,
        responseId: responseId,
        terminalEvidence: Some(domain.TerminalEvidence(
            "fixture", "fixture_terminal", rawStopReason: stopReason,
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "fixture-v1"
        )),
        completionDisposition: if (hasTool) {
            domain.CompletionDisposition.ToolUse
        } else { domain.CompletionDisposition.Complete },
        decisionOutcome: if (hasRefusal) {
            domain.DecisionOutcome.Refusal
        } else if (hasTool) {
            domain.DecisionOutcome.ToolCalls
        } else { domain.DecisionOutcome.Response },
        validationVersion: 1
    )
}

func fixtureHubProcessBlock(prompt: String): ?domain.ModelBlock {
    let prefix = "fixture hub process "
    if (!prompt.startsWith(prefix)) {
        return None
    }
    let action = prompt[prefix.size..prompt.size]
    let fields = ArrayList<domain.ValueField>()
    let op: String
    match (action) {
        case "start" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/bash")
                )
            )
            fields.add(
                domain.ValueField(
                    "args",
                    domain.listValue(
                        [
                            domain.textValue("-lc"),
                            domain.textValue(
                                "printf 'READY\\n'; " + "while IFS= read -r -d $'\\r' line; do " +
                                    "printf 'ECHO:%s\\n' \"$line\"; " + "[ \"$line\" = quit ] && exit 0; done")
                        ]
                    )
                )
            )
            fields.add(
                domain.ValueField(
                    "pty",
                    domain.boolValue(false)
                )
            )
            fields.add(
                domain.ValueField(
                    "ready",
                    domain.objectValue(
                        [
                            domain.ValueField(
                                "log",
                                domain.textValue("READY")
                            ),
                            domain.ValueField(
                                "timeout",
                                domain.integerValue(2)
                            )
                        ]
                    )
                )
            )
        case "start-again" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/bash")
                )
            )
            fields.add(
                domain.ValueField(
                    "args",
                    domain.listValue(
                        [
                            domain.textValue("-lc"),
                            domain.textValue("printf 'SECOND\\n'")
                        ]
                    )
                )
            )
            fields.add(
                domain.ValueField(
                    "pty",
                    domain.boolValue(false)
                )
            )
        case "logs" =>
            op = "logs"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "lines",
                    domain.integerValue(20)
                )
            )
        case "send" =>
            op = "send"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "text",
                    domain.textValue("hello")
                )
            )
        case "wait" =>
            op = "wait"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "pattern",
                    domain.textValue("ECHO:hello")
                )
            )
            fields.add(
                domain.ValueField(
                    "timeout",
                    domain.integerValue(2)
                )
            )
        case "describe" =>
            op = "describe"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
        case "restart" =>
            op = "restart"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
            fields.add(
                domain.ValueField(
                    "network",
                    domain.objectValue([
                        domain.ValueField("mode", domain.textValue("denied"))
                    ])
                )
            )
        case "ps" => op = "ps"
        case "stop" =>
            op = "stop"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-daemon")
                )
            )
        case "persist" =>
            op = "start"
            fields.add(
                domain.ValueField(
                    "name",
                    domain.textValue("fixture-persist")
                )
            )
            fields.add(
                domain.ValueField(
                    "application",
                    domain.textValue("/bin/true")
                )
            )
            fields.add(
                domain.ValueField(
                    "persist",
                    domain.boolValue(true)
                )
            )
        case _ => return None
    }
    fields.add(domain.ValueField("op", domain.textValue(op)))
    Some(
        domain.ModelBlock(
            domain.ModelBlockKind.ToolCall,
            callId: "fixture-hub-process-" + action + "-call",
            name: if (["ps", "logs", "describe", "wait"].contains(op)) {
                "plugin.axyndra:workflow.hub_process_read"
            } else { "plugin.axyndra:workflow.hub_process" },
            arguments: domain.objectValue(fields.toArray())
        )
    )
}

func hasTool(
    tools: Array<domain.ModelToolDefinition>,
    name: String
): Bool {
    for (tool in tools where tool.name == name) {
        return true
    }
    false
}

public func fixtureModelPort(): ports.ModelPort {
    FixtureModelPort()
}

public func primaryFixtureModelPort(): ports.ModelPort {
    FixtureModelPort(failFirst: true)
}

func messageText(message: domain.ModelMessage): String {
    var result = ""
    for (block in message.blocks) {
        match (block.kind) {
            case domain.ModelBlockKind.Text => result += block.text
            case _ => ()
        }
    }
    result
}

