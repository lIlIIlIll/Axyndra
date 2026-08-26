package chaos_contract

import yjson_support.*

import yjson.*

import agent_core.*
import agent_domain.*
import agent_embed.*
import agent_testkit.*
import axyndra_agent_testkit.*
import tool_runtime.*
import std.collection.*
import std.sync.*

main(): Int64 {
    partialStreamContract()
    retryStormIsBounded()
    modelCancellationRace()
    toolCancellationRace()
    println("chaos contract passed")
    0
}

func partialStreamContract(): Unit {
    let model = ScriptedModelPort([modelFailureStep(
        AgentError(
            AgentErrorKind.Transport,
            "chaos.sse_truncated",
            "SSE stream ended before completion"
        ),
        events: [ModelEvent.TextDelta("half"), ModelEvent.TextDelta("half")]
    )])
    let runtime = sdk(model, ToolCatalog())
    let probe = PartialStreamProbe()
    let result = runtime.run("partial stream", eventSink: probe.sink())
    let transcript = runtime.transcript().value().getOrThrow()
    expect(result.isError() && errorCode(result) == "chaos.sse_truncated" && model.calls() == 1,
        "a truncated stream terminates the run exactly once")
    expect(probe.textDeltas() == 2,
        "duplicate partial deltas remain observable to event consumers")
    expect(!containsAssistantText(transcript, "half"),
        "partial stream text is never committed as a completed answer")
}

func retryStormIsBounded(): Unit {
    let faults = FaultPlan(rules: [FaultRule("model.request", repeat: true)])
    let steps = ArrayList<ScriptedModelStep>()
    for (_ in 0..16) {
        if (faults.shouldFail("model.request")) {
            steps.add(modelFailureStep(AgentError(
                AgentErrorKind.Transport,
                "chaos.retry_storm",
                "retryable transport failure",
                retryable: true
            )))
        }
    }
    let model = ScriptedModelPort(steps.toArray())
    let result = sdk(
        model,
        ToolCatalog(),
        budget: runtimeBudget(maxModelRequests: 3),
        autoRetry: true
    ).run("bounded retry storm")
    expect(result.isError() && errorCode(result) == "chaos.retry_storm" && model.calls() == 2,
        "retryable failures stop at the frozen RecoveryV1 attempt ceiling")
    expect(faults.calls("model.request") == 16,
        "named deterministic fault plan assembles the recovery stress script")
}

func modelCancellationRace(): Unit {
    let model = ScriptedModelPort([modelCancellationStep(cancellationWaitMillis: 2000)])
    let runtime = sdk(model, ToolCatalog())
    let cancellation = CancellationSource()
    let future = spawn {
        runtime.run("cancel model", cancellation: cancellation.token)
    }
    waitFor({ => model.calls() == 1 }, "model did not start")
    let requestId = model.requests()[0].requestId
    cancellation.cancel()
    waitForFuture(future, "cancelled model run did not settle")
    let result = future.get()
    cancellation.close()
    expect(result.isError() && errorKind(result) == Some(AgentErrorKind.Cancelled) &&
        model.wasCancelled(requestId),
        "CancellationToken reaches the active model request")
}

func toolCancellationRace(): Unit {
    let catalog = ToolCatalog()
    let tool = ScriptedToolExecutor([
        ScriptedToolStep(waitForCancellation: true, cancellationWaitMillis: 2000)
    ])
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "hang",
                "wait until cancelled",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        tool
    ).isOk(), "hanging tool registers")
    let model = ScriptedModelPort([modelReplyStep(ModelReply([
        ModelBlock(
            ModelBlockKind.ToolCall,
            callId: "hang-call",
            name: "hang",
            arguments: objectValue([])
        )
    ],
        stopReason: "tool_use",
        terminalEvidence: Some(TerminalEvidence(
            "fixture", "message_stop", rawStopReason: "tool_use",
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "chaos-contract-v1"
        )),
        completionDisposition: CompletionDisposition.ToolUse,
        decisionOutcome: DecisionOutcome.ToolCalls,
        validationVersion: 1
    ))])
    let runtime = sdk(
        model,
        catalog,
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        modelCapabilities: ModelCapabilities(
            toolCalling: true,
            contextWindowTokens: 4096,
            maxOutputTokens: 256
        )
    )
    let cancellation = CancellationSource()
    let future = spawn {
        runtime.run("cancel tool", cancellation: cancellation.token)
    }
    waitFor({ => tool.calls().size == 1 }, "tool did not start")
    cancellation.cancel()
    waitForFuture(future, "cancelled tool run did not settle")
    let result = future.get()
    cancellation.close()
    expect(result.isError() && errorKind(result) == Some(AgentErrorKind.Cancelled) &&
        tool.runWasCancelled("chaos-run-1"),
        "CancellationToken reaches an active tool wave")
}

class PartialStreamProbe {
    private let lock = Mutex()
    private var deltas: Int64 = 0

    func sink(): AgentEventSink {
        { event =>
            match (event.payload) {
                case AgentEventPayload.TextDelta(_) =>
                    lock.lock()
                    try { deltas += 1 } finally { lock.unlock() }
                case _ => ()
            }
        }
    }

    func textDeltas(): Int64 {
        lock.lock()
        try { deltas } finally { lock.unlock() }
    }
}

func containsAssistantText(messages: Array<ModelMessage>, target: String): Bool {
    for (message in messages where message.role == ModelRole.Assistant) {
        for (block in message.blocks where block.kind == ModelBlockKind.Text &&
             block.text.contains(target)) { return true }
    }
    false
}

func sdk(
    model: ScriptedModelPort,
    catalog: ToolCatalog,
    budget!: ResourceBudget = runtimeBudget(),
    autoRetry!: Bool = false,
    capabilities!: CapabilitySet = CapabilitySet(),
    modelCapabilities!: ModelCapabilities = ModelCapabilities(
        contextWindowTokens: 4096,
        maxOutputTokens: 256
    )
): AgentSdk {
    AgentBuilder()
        .provider(model, label: "chaos-model")
        .model("chaos-model", modelCapabilities)
        .tools(catalog, label: "chaos-tools")
        .session(SessionId("chaos-session"))
        .runRepository(MemoryRunRepository(), label: "chaos-runs")
        .policy(DefaultCapabilityPolicy(mode: ApprovalMode.Yolo), label: "chaos-policy")
        .budget(budget)
        .prompt(PromptBuilder().add(PromptSection(
            PromptSectionKind.Base,
            PromptTrust.System,
            PromptStability.Stable,
            "chaos",
            "1",
            "fault-injection contract"
        )))
        .operations(MemoryOperationRepository())
        .audit(RecordingAuditPort())
        .ids(DeterministicIds(prefix: "chaos"))
        .capabilities(capabilities)
        .autoRetry(autoRetry)
        .build().value().getOrThrow()
}

func runtimeBudget(maxModelRequests!: Int64 = 4): ResourceBudget {
    ResourceBudget(
        maxInputTokens: 2048,
        maxOutputTokens: 256,
        maxModelRequests: maxModelRequests,
        maxTurns: 4,
        maxToolCalls: 4,
        maxWallMillis: 10000,
        maxIdleMillis: 2000,
        maxConcurrentTools: 2
    )
}

func errorCode<T>(value: Result<T>): String {
    match (value) {
        case Result.Ok(_) => ""
        case Result.Err(error) => error.code
    }
}

func errorKind<T>(value: Result<T>): ?AgentErrorKind {
    match (value) {
        case Result.Ok(_) => None
        case Result.Err(error) => Some(error.kind)
    }
}

func waitFor(condition: () -> Bool, message: String): Unit {
    var attempts: Int64 = 0
    while (!condition() && attempts < 2000) {
        sleep(Duration.millisecond)
        attempts += 1
    }
    if (!condition()) { throw IllegalStateException(message) }
}

func waitForFuture<T>(future: Future<T>, message: String): Unit {
    var waited: Int64 = 0
    while (future.tryGet().isNone() && waited < 4000) {
        sleep(Duration.millisecond)
        waited += 1
    }
    if (future.tryGet().isNone()) { throw IllegalStateException(message) }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
