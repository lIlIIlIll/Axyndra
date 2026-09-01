package testkit_contract

import agent_domain.*
import agent_testkit.*
import tool_runtime.*

main(): Int64 {
    scriptedModelContract()
    cancellationContract()
    scriptedToolContract()
    memoryPortsContract()
    scriptedPolicyContract()
    deterministicControlContract()
    benchmarkContract()
    println("testkit contract passed")
    0
}

func scriptedPolicyContract(): Unit {
    let policy = ScriptedCapabilityPolicy([
        ScriptedPolicyStep(PermissionRequirement.Confirm, reason: "review fixture"),
        ScriptedPolicyStep(PermissionRequirement.Deny, reason: "deny fixture")
    ])
    let descriptor = ToolDescriptor(
        ModelToolDefinition("policy_fixture", "policy fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceWrite),
        sideEffecting: true
    )
    let context = ToolInvocationContext(
        RunId("policy-run"),
        SessionId("policy-session"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)])
    )
    expect(policy.evaluate(context, descriptor).requirement == PermissionRequirement.Confirm,
        "scripted policy returns its first production-domain decision")
    expect(policy.evaluate(context, descriptor).requirement == PermissionRequirement.Deny,
        "scripted policy advances deterministically")
    expect(policy.calls().size == 2 && policy.calls()[0].toolName == "policy_fixture",
        "scripted policy records read-only request projections")
}

func scriptedModelContract(): Unit {
    let reply = ModelReply(
        [ModelBlock(ModelBlockKind.Text, text: "done")],
        stopReason: "end_turn"
    )
    let model = ScriptedModelPort([
        modelFailureStep(
            AgentError(AgentErrorKind.Transport, "fixture.truncated", "truncated SSE"),
            events: [ModelEvent.TextDelta("par"), ModelEvent.TextDelta("par")]
        ),
        modelReplyStep(reply, events: [ModelEvent.TextDelta("done"), ModelEvent.Completed])
    ])
    let recorded = RecordingModelEvents()
    let first = model.execute(request("request-1"), recorded.sink())
    expect(first.isError(), "a scripted partial stream terminates with its configured failure")
    expect(recorded.snapshot().size == 2, "duplicate deltas remain observable")
    expect(model.execute(request("request-2"), recorded.sink()).isOk(), "the next scripted retry succeeds")
    expect(model.requests().size == 2 && model.calls() == 2, "model requests are deterministic and inspectable")
}

func cancellationContract(): Unit {
    let model = ScriptedModelPort([modelCancellationStep(cancellationWaitMillis: 1000)])
    let future = spawn { model.execute(request("cancel-me"), { _ => () }) }
    sleep(Duration.millisecond * 5)
    expect(model.cancel("cancel-me").isOk(), "scripted cancellation is accepted")
    waitForFuture(future, "scripted model cancellation did not settle")
    let result = future.get()
    expect(result.isError() && model.wasCancelled("cancel-me"), "a stalled request exits through cancellation")
}

func scriptedToolContract(): Unit {
    let tool = ScriptedToolExecutor([
        ScriptedToolStep(result: Some(textValue("ok"))),
        ScriptedToolStep(waitForCancellation: true, cancellationWaitMillis: 1000)
    ])
    let context = ToolInvocationContext(
        RunId("run-1"),
        SessionId("session-1"),
        CapabilitySet()
    )
    expect(tool.execute(context, ToolCall("call-1", "fixture", objectValue([]))).isOk(),
        "scripted tool returns its configured result")
    let waiting = spawn {
        tool.execute(context, ToolCall("call-2", "fixture", objectValue([])))
    }
    sleep(Duration.millisecond * 5)
    let _ = tool.cancel(RunId("run-1"))
    waitForFuture(waiting, "scripted tool cancellation did not settle")
    expect(waiting.get().isError(), "a hanging tool can reproduce cancellation races")
    expect(tool.calls().size == 2, "tool calls are recorded")
}

func memoryPortsContract(): Unit {
    let session = SessionId("memory-session")
    let otherSession = SessionId("memory-session-other")
    let runs = MemoryRunRepository()
    let run = RunId("memory-run")
    expect(runs.save(RunSnapshot(run, session, RunState.Running)).isOk(),
        "memory run repository stores a snapshot")
    expect(runs.append(AgentEvent(
        EventMeta(1, TraceId("testkit-contract"), run),
        AgentEventPayload.RunStarted
    )).isOk(),
        "memory run repository appends events")
    expect(runs.events(run, 0).value().getOrThrow().events.size == 1,
        "memory run repository pages recorded events")
    expect(runs.append(AgentEvent(
        EventMeta(1, TraceId("testkit-contract"), run),
        AgentEventPayload.Audit("duplicate", objectValue([]))
    )).isError(),
        "memory run events reject duplicate sequence numbers")

    let approvalRun = RunId("approval-run")
    let approvalOperation = OperationId("approval-operation")
    expect(runs.save(RunSnapshot(approvalRun, session, RunState.WaitingApproval)).isOk(),
        "memory run repository stores an approval snapshot")
    let pending = continuation(
        approvalRun,
        session,
        approvalOperation,
        "approval-call",
        "approval-hash"
    )
    expect(runs.saveContinuation(pending).isOk() && runs.saveContinuation(pending).isOk(),
        "an identical continuation can be replayed idempotently")
    expect(runs.saveContinuation(continuation(
        approvalRun,
        session,
        approvalOperation,
        "approval-call",
        "different-hash"
    )).isError(), "a continuation binding cannot be overwritten")
    let decision = ApprovalDecisionReceipt(
        approvalOperation,
        approvalRun,
        session,
        "approval-call",
        "approval-hash",
        ApprovalDecision.Approve
    )
    expect(runs.recordDecision(decision).isOk() && runs.recordDecision(decision).isOk(),
        "the same approval decision can be replayed atomically")
    expect(runs.saveContinuation(RunContinuation(
        approvalRun,
        session,
        "drifted-model",
        "fixture prompt",
        ApprovalRequest(
            OperationId("next-approval-operation"),
            "next-approval-call",
            "fixture-tool",
            Capability(CapabilityKind.WorkspaceRead),
            sessionId: session.value,
            argumentHash: "next-approval-hash"
        )
    )).isError(), "an approval receipt cannot authorize request drift")
    expect(runs.recordDecision(ApprovalDecisionReceipt(
        approvalOperation,
        approvalRun,
        session,
        "approval-call",
        "approval-hash",
        ApprovalDecision.Reject
    )).isError(), "an approval decision cannot be changed")

    let missingRun = RunId("missing-continuation-run")
    expect(runs.save(RunSnapshot(missingRun, otherSession, RunState.WaitingApproval)).isOk() &&
        errorKind(runs.pendingContinuation(otherSession)) == Some(AgentErrorKind.RecoveryRequired),
        "an awaiting-approval snapshot without continuation requires recovery")
    let duplicateRun = RunId("duplicate-pending-run")
    expect(runs.save(RunSnapshot(duplicateRun, session, RunState.WaitingApproval)).isOk() &&
        errorKind(runs.pendingContinuation(session)) == Some(AgentErrorKind.RecoveryRequired),
        "multiple pending approval runs are rejected as ambiguous")

    let operations = MemoryOperationRepository()
    let operation = OperationId("memory-operation")
    let record = OperationRecord(
        operation,
        run,
        OperationStatus.Prepared,
        Capability(CapabilityKind.WorkspaceRead),
        "digest"
    )
    expect(operations.prepare(record).isOk(), "memory operation repository prepares work")
    expect(operations.transition(operation, OperationStatus.Prepared, OperationStatus.Approved).isOk(),
        "memory operation repository enforces expected transitions")
    let receipt = OperationReceipt(operation, true, objectValue([]))
    expect(operations.saveReceipt(receipt).isOk() && operations.receipt(operation).isOk(),
        "memory operation repository retains receipts")
    expect(operations.saveReceipt(receipt).isOk(),
        "an identical operation receipt can be replayed")
    expect(operations.saveReceipt(OperationReceipt(
        operation,
        false,
        textValue("different"),
        isError: true
    )).isError(), "an operation receipt cannot be overwritten")

    let audit = RecordingAuditPort()
    expect(audit.append(AgentEvent(
        EventMeta(2, TraceId("testkit-contract"), run),
        AgentEventPayload.Audit("recording", objectValue([]))
    )).isOk() && audit.events().size == 1,
        "recording audit exposes captured events")
}

func continuation(
    runId: RunId,
    sessionId: SessionId,
    operationId: OperationId,
    callId: String,
    argumentHash: String
): RunContinuation {
    RunContinuation(
        runId,
        sessionId,
        "fixture-model",
        "fixture prompt",
        ApprovalRequest(
            operationId,
            callId,
            "fixture-tool",
            Capability(CapabilityKind.WorkspaceRead),
            sessionId: sessionId.value,
            argumentHash: argumentHash
        )
    )
}

func deterministicControlContract(): Unit {
    let ids = DeterministicIds(prefix: "contract")
    expect(ids.nextRunId().value == "contract-run-1", "run IDs are deterministic")
    expect(ids.nextSessionId().value == "contract-session-1", "session IDs are deterministic")
    expect(ids.nextOperationId().value == "contract-operation-1", "operation IDs are deterministic")
    let clock = ManualClock(initialMillis: 10)
    expect(clock.advance(5) == 15 && clock.monotonicMillis() == 15, "manual time advances explicitly")
}

func benchmarkContract(): Unit {
    let series = AgentBenchmarkSeries("contract", warmupRuns: 2)
    for (value in [50, 10, 40, 20, 30]) {
        series.add(AgentBenchmarkSample(
            ttftMillis: Some(value),
            generationMillis: Some(100),
            outputTokens: Some(value),
            rssBytes: None
        ))
    }
    let summary = series.summary()
    expect(summary.totalSamples == 5 && summary.warmups == 2 && summary.samples == 3,
        "benchmark summary excludes the configured warmup observations")
    expect(summary.ttftMillis.minimum == Some(20), "measured benchmark values are sorted for minimum")
    expect(summary.ttftMillis.p50 == Some(30), "benchmark exposes p50")
    expect(summary.ttftMillis.p95 == Some(40) && summary.ttftMillis.p99 == Some(40),
        "benchmark exposes nearest-rank p95 and p99")
    expect(summary.tokensPerSecondMilli.count == 3, "throughput is derived without floating-point drift")
    expect(summary.rssBytes.count == 0 && summary.rssBytes.p50.isNone(),
        "unavailable memory remains unavailable")
}

func request(id: String): ModelRequest {
    ModelRequest("fixture", [], requestId: id, streaming: true)
}

func errorKind<T>(value: Result<T>): ?AgentErrorKind {
    match (value) {
        case Result.Ok(_) => None
        case Result.Err(error) => Some(error.kind)
    }
}

func waitForFuture<T>(future: Future<T>, message: String): Unit {
    var waited: Int64 = 0
    while (future.tryGet().isNone() && waited < 2000) {
        sleep(Duration.millisecond)
        waited += 1
    }
    if (future.tryGet().isNone()) { throw IllegalStateException(message) }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
