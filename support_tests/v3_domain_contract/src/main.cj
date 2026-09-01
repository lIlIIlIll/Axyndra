package v3_domain_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*

main(): Int64 {
    typedIdentifiersContract()
    typedEventsContract()
    modelCapabilitiesContract()
    cancellationContract()
    runStateContract()
    executionBudgetContract()
    println("v3 domain contract passed")
    0
}

func typedIdentifiersContract(): Unit {
    expect(TraceId(" trace-1 ").value == "trace-1", "trace id is normalized")
    expect(TurnId("turn-1").value == "turn-1", "turn id")
    expect(RequestId("request-1").value == "request-1", "request id")
    expect(ToolBatchId("batch-1").value == "batch-1", "tool batch id")
    expect(ToolCallId("call-1").value == "call-1", "tool call id")
    expect(OperationId("operation-1").value == "operation-1", "operation id")
    expect(rejects({ => TraceId("  ") }), "empty typed id is rejected")
}

func typedEventsContract(): Unit {
    let runId = RunId("run-event")
    let traceId = TraceId("trace-event")
    let requestId = RequestId("request-event")
    let meta = EventMeta(
        7,
        traceId,
        runId,
        occurredAtMillis: 42,
        turnId: Some(TurnId("turn-event")),
        requestId: Some(requestId)
    )
    let event = AgentEvent(meta, AgentEventPayload.TextDelta("hello"))
    expect(event.sequence == 7 && event.runId.value == "run-event", "typed event exposes routing envelope")
    expect(event.kind == AgentEventKind.Model, "typed event derives coarse routing kind")
    expect(event.meta.traceId.value == "trace-event", "typed event keeps trace correlation")
    expect(match (event.meta.requestId) {
        case Some(value) => value.value == "request-event"
        case None => false
    }, "typed event keeps request correlation")
    expect(match (event.payload) {
        case AgentEventPayload.TextDelta(value) => value == "hello"
        case _ => false
    }, "typed event payload is exhaustively matchable")
    expect(match (event.detail.field("text")) {
        case Some(value) => value.text == "hello"
        case None => false
    }, "typed event projects a protocol-neutral detail")

    let extension = AgentEvent(
        EventMeta(1, traceId, runId),
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([]))
    )
    expect(match (extension.payload) {
        case AgentEventPayload.Extension(AgentEventKind.Audit, _) => true
        case _ => false
    }, "independently versioned events use the explicit extension variant")
}

func modelCapabilitiesContract(): Unit {
    expect(rejects({ => ModelCapabilities(parallelToolCalling: true) }),
           "parallel tool calling implies tool calling")
    let schema = objectValue([ValueField("type", textValue("object"))])
    let request = ModelRequest(
        "fixture",
        [],
        tools: [ModelToolDefinition("echo", "echo", schema)],
        thinking: ThinkingLevel.Low,
        maxOutputTokens: 64,
        parallelToolCalls: true,
        cachePolicy: ModelCachePolicy.StablePrefix,
        cacheKey: "domain-contract"
    )
    let limited = ModelCapabilities(
        toolCalling: true,
        contextWindowTokens: 4096,
        maxOutputTokens: 128
    )
    expect(limited.validate(request).isError(), "unsupported requested capability fails before transport")
    let complete = ModelCapabilities(
        toolCalling: true,
        parallelToolCalling: true,
        reasoning: true,
        structuredOutput: true,
        promptCache: true,
        contextWindowTokens: 4096,
        maxOutputTokens: 128
    )
    expect(complete.validate(request).isOk(), "supported request passes capability validation")
    expect(complete.require(ModelFeature.StructuredOutput).isOk(), "structured output capability is explicit")
    let image = ModelImage(
        ModelImageSourceKind.Base64,
        "aGVsbG8=",
        mediaType: "image/png"
    )
    let imageRequest = ModelRequest(
        "fixture",
        [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Image, image: Some(image))])],
        thinking: ThinkingLevel.Off,
        maxOutputTokens: 64,
        parallelToolCalls: false
    )
    expect(complete.validate(imageRequest).isError(), "vision input requires an explicit model capability")
    expect(ModelCapabilities(
        vision: true,
        contextWindowTokens: 4096,
        maxOutputTokens: 128
    ).validate(imageRequest).isOk(), "validated image input reaches a vision-capable model")
    expect(rejects({ => ModelImage(ModelImageSourceKind.Url, "file:///etc/passwd") }),
           "image URLs reject non-network schemes")
    expect(rejects({ => ModelImage(
        ModelImageSourceKind.Base64,
        "not-base64",
        mediaType: "image/png"
    ) }), "embedded images reject malformed base64")
    expect(rejects({ => ModelBlock(ModelBlockKind.Image) }),
           "image blocks cannot exist without typed image data")
}

func cancellationContract(): Unit {
    let base = agentUtcMillis()
    let parent = CancellationSource(deadlineMillis: base + 200)
    let child = parent.child(deadlineMillis: base + 150)
    let callbacks = Counter()
    let registration = child.token.onCancel({ _ => callbacks.increment() }, nowMillis: base)
    expect(child.token.deadlineMillis == base + 150, "child inherits the earliest deadline")
    expect(!child.token.isCancelled(nowMillis: base + 149), "deadline does not fire early")
    expect(child.token.isCancelled(nowMillis: base + 150), "deadline cancellation is cooperative and deterministic")
    expect(callbacks.value() == 1, "deadline invokes registered callbacks once")
    expect(match (child.token.reason(nowMillis: base + 150)) {
        case Some(reason) => reason.kind == CancellationReasonKind.Deadline
        case None => false
    }, "deadline reason is typed")
    expect(child.token.check(nowMillis: base + 150).isError(), "cancelled token returns a typed error")
    registration.dispose()

    let propagated = parent.child()
    let parentCallbacks = Counter()
    propagated.token.onCancel({ _ => parentCallbacks.increment() }, nowMillis: base)
    expect(parent.cancel(reason: Some(CancellationReason(
        CancellationReasonKind.Shutdown,
        "run.shutdown",
        "runtime is shutting down",
        cancelledAtMillis: base + 100
    ))), "first cancellation wins")
    expect(!parent.cancel(), "cancellation is idempotent")
    expect(propagated.token.isCancelled(nowMillis: base + 100), "parent cancellation propagates")
    expect(parentCallbacks.value() == 1, "propagated callback runs once")
    expect(match (propagated.token.reason(nowMillis: base + 100)) {
        case Some(reason) => reason.kind == CancellationReasonKind.Parent
        case None => false
    }, "propagated reason records the parent boundary")
    propagated.close()
    child.close()
    parent.close()
}

func runStateContract(): Unit {
    let machine = RunStateMachine()
    expect(machine.state() == RunState.Created, "state machine starts created")
    expect(machine.transition(RunState.WaitingApproval).isError(),
           "invalid transition returns a typed error")
    let started = machine.transition(RunState.Running, reason: "accepted")
        .value().getOrThrow()
    expect(started.sequence == 1 && started.from == RunState.Created &&
           started.to == RunState.Running, "legal transition is sequenced")
    let waiting = machine.preview(RunState.WaitingApproval, reason: "tool approval")
        .value().getOrThrow()
    expect(machine.commitPreview(waiting).value().getOrThrow().sequence == 2,
           "owned preview commits for the current state")
    expect(machine.commitPreview(waiting).isError(),
           "stale transition proposal is rejected")
    expect(machine.transition(RunState.Cancelling).isOk(),
           "approval wait can enter cancellation")
    expect(machine.transition(RunState.Cancelled).isOk(),
           "cancellation settles as a cancelled terminal run")
    expect(isTerminalRunState(machine.state()), "completed state is terminal")
    expect(machine.transition(RunState.Running).isError(), "terminal runs cannot restart")
}

func executionBudgetContract(): Unit {
    let budget = ExecutionBudget(
        maxTurns: 2,
        maxToolCalls: 3,
        maxConcurrentTools: 2,
        maxInputTokens: 100,
        maxOutputTokens: 40,
        maxCostMicros: 20,
        deadlineMillis: 1000
    )
    let ledger = budget
    expect(match (ledger.reserve(
        BudgetCharge(
            turns: 1,
            toolCalls: 2,
            toolsStarted: 2,
            inputTokens: 60,
            outputTokens: 10,
            costMicros: 5
        ),
        nowMillis: 100
    )) {
        case Result.Ok(usage) => usage.activeTools == 2 && usage.toolCalls == 2
        case Result.Err(_) => false
    }, "budget reservation atomically records cumulative and concurrent usage")
    expect(match (ledger.reserve(BudgetCharge(toolsStarted: 1), nowMillis: 100)) {
        case Result.Err(error) => error.code == "budget.concurrent_tools_exceeded"
        case Result.Ok(_) => false
    }, "concurrency limit is enforced")
    expect(ledger.snapshot().activeTools == 2,
           "rejected reservation does not partially consume budget")
    expect(ledger.releaseTools().value().getOrThrow().activeTools == 1,
           "tool completion releases only live concurrency")
    expect(match (ledger.reserve(BudgetCharge(costMicros: 16), nowMillis: 100)) {
        case Result.Err(error) => error.code == "budget.cost_exceeded"
        case Result.Ok(_) => false
    }, "cost budget is cumulative")
    expect(match (ledger.checkDeadline(nowMillis: 1000)) {
        case Result.Err(error) => error.code == "budget.deadline_exceeded"
        case Result.Ok(_) => false
    }, "absolute deadline is enforced")

    let resource = ResourceBudget(
        maxTurns: 4,
        maxToolCalls: 8,
        maxConcurrentTools: 3,
        maxCostMicros: 99,
        deadlineMillis: 1234
    )
    let converted = executionBudgetFrom(resource)
    expect(converted.maxConcurrentTools == 3 && converted.maxCostMicros == 99 &&
           converted.deadlineMillis == 1234,
           "resource configuration converts to an execution budget")
}

class Counter {
    private var count: Int64 = 0

    func increment(): Unit { count += 1 }
    func value(): Int64 { count }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}

func rejects(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}
