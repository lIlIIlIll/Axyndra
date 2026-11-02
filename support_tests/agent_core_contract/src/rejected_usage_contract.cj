package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import tool_runtime.*

class RejectedReplyUsageModel <: ModelPort {
    let mode: String
    var calls: Int64 = 0

    init(mode!: String = "limited") { this.mode = mode }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        if (calls == 1 && mode == "adapter_error") {
            return Result.Err(AgentError(
                AgentErrorKind.Transport, "fixture.billed_transport_error", "billed transport error",
                retryable: true,
                fields: [
                    ErrorField("usage_input_tokens", "100"),
                    ErrorField("usage_output_tokens", "20"),
                    ErrorField("usage_reasoning_tokens", "5"),
                    ErrorField("usage_cache_read_tokens", "30"),
                    ErrorField("usage_cache_write_tokens", "10")
                ]
            ))
        }
        if (calls == 1 && mode != "accepted") {
            let terminal = TerminalEvidence(
                "contract", "message_stop", rawStopReason: "max_tokens",
                messageTerminalObserved: true, streamEofObserved: true,
                adapterVersion: "rejected-usage-v1"
            )
            events(ModelEvent.ProviderProgress(ProviderStreamEvent.MessageTerminalObserved(terminal)))
            return Result.Ok(ModelReply(
                [ModelBlock(ModelBlockKind.Reasoning, text: "provisional reasoning")],
                stopReason: "max_tokens", acceptedOutput: false,
                providerId: "usage-fixture", responseId: "rejected-usage-response",
                usage: Some(if (mode == "zero") {
                    ModelUsage(source: ModelUsageSource.ProviderFinal,
                        evidence: Some(ModelUsageEvidence("contract", "message_stop", providerResponseId: "rejected-usage-response")))
                } else {
                    ModelUsage(inputTokens: 100, outputTokens: 20, reasoningTokens: 5,
                        cacheReadTokens: 30, cacheWriteTokens: 10,
                        source: ModelUsageSource.ProviderFinal,
                        evidence: Some(ModelUsageEvidence("contract", "message_stop", providerResponseId: "rejected-usage-response")))
                }),
                terminalEvidence: Some(terminal),
                completionDisposition: CompletionDisposition.OutputLimited,
                validationVersion: 1
            ))
        }
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "usage settled")],
            stopReason: "end_turn", inputTokens: 20, outputTokens: 4,
            responseId: "accepted-usage-response"
        ))
    }
}

func rejectedUsagePricing(): ModelPricing {
    ModelPricing(
        inputMicrosPerMillion: Some(1000000), outputMicrosPerMillion: Some(2000000),
        cacheReadMicrosPerMillion: Some(500000), cacheWriteMicrosPerMillion: Some(1500000)
    )
}

func rejectedUsageRequest(
    name: String,
    budget: ResourceBudget,
    pricing: ?ModelPricing,
    autoRetry!: Bool = true
): AgentRunRequest {
    AgentRunRequest(
        RunId("rejected-usage-" + name), SessionId("rejected-usage-session-" + name),
        "usage-fixture", "account every billed attempt exactly once",
        thinking: ThinkingLevel.Medium,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
            "usage-fixture", ThinkingCapabilities(ThinkingControlMode.Effort,
                supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium]), 100000
        )),
        budget: budget, pricing: pricing, autoRetry: autoRetry
    )
}

func expectRejectedUsage(
    snapshot: RunSnapshot,
    requests: Int64,
    input: Int64,
    output: Int64,
    reasoning: Int64,
    cacheRead: Int64,
    cacheWrite: Int64,
    cost: ?Int64,
    message: String
): Unit {
    expect(snapshot.modelRequests == requests && snapshot.inputTokens == input &&
        snapshot.outputTokens == output && snapshot.reasoningTokens == reasoning &&
        snapshot.cacheReadTokens == cacheRead && snapshot.cacheWriteTokens == cacheWrite &&
        snapshot.costMicros == cost, message)
}

func rejectedUsageCase(
    name: String,
    budget: ResourceBudget,
    calls: Int64,
    fails: Bool,
    mode!: String = "limited",
    priced!: Bool = true,
    autoRetry!: Bool = true,
    budgetFailure!: Bool = false
): Unit {
    let runs = MemoryRuns()
    let model = RejectedReplyUsageModel(mode: mode)
    let catalog = ToolCatalog()
    let request = rejectedUsageRequest(name, budget,
        if (priced) { Some(rejectedUsagePricing()) } else { None }, autoRetry: autoRetry)
    let result = AgentCore(model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog
    ).start(request)
    expect(model.calls == calls && result.isError() == fails,
        name + " keeps the expected outcome and bounded provider call count")
    if (budgetFailure) {
        expect(match (result) {
            case Result.Err(error) => error.kind == AgentErrorKind.BudgetExceeded
            case _ => false
        }, name + " returns the budget error instead of retrying the original validation error")
    } else if (fails) {
        expect(result.error().getOrThrow().code == "model.output_limited_before_decision",
            name + " retains the output-limit root cause")
    }
    let acceptedOnly = mode == "accepted"
    let zero = mode == "zero"
    let snapshot = runs.find(request.runId).value().getOrThrow()
    let cost: ?Int64 = if (!priced) { None } else if (acceptedOnly) { Some(28) } else if (zero) {
        Some(0)
    } else { Some(if (calls == 2) { 158 } else { 130 }) }
    expectRejectedUsage(snapshot, calls,
        if (acceptedOnly) { 20 } else if (zero) { 0 } else if (calls == 2) { 120 } else { 100 },
        if (acceptedOnly) { 4 } else if (zero) { 0 } else if (calls == 2) { 24 } else { 20 },
        if (acceptedOnly || zero) { 0 } else { 5 },
        if (acceptedOnly || zero) { 0 } else { 30 },
        if (acceptedOnly || zero) { 0 } else { 10 }, cost,
        name + " accounts all observed buckets and fixed-point costs exactly once")
}

func rejectedReplyUsageContract(): Unit {
    // Each reply fits a per-request ceiling of 20, while the combined output is 24.
    rejectedUsageCase("recovered", ResourceBudget(maxOutputTokens: 20), 2, false)
    rejectedUsageCase("unknown-price", ResourceBudget(maxOutputTokens: 20), 2, false, priced: false)
    rejectedUsageCase("adapter-error", ResourceBudget(maxOutputTokens: 20), 2, false, mode: "adapter_error")
    rejectedUsageCase("accepted-once", ResourceBudget(maxOutputTokens: 20), 1, false, mode: "accepted")
    rejectedUsageCase("no-auto-retry", ResourceBudget(maxOutputTokens: 20), 1, true, autoRetry: false)
    rejectedUsageCase("observed-zero", ResourceBudget(maxOutputTokens: 20), 1, true,
        mode: "zero", autoRetry: false)
    rejectedUsageCase("request-ceiling", ResourceBudget(maxOutputTokens: 19), 1, true, budgetFailure: true)
    rejectedUsageCase("total-first", ResourceBudget(maxOutputTokens: 20, maxTotalOutputTokens: 19),
        1, true, budgetFailure: true)
    rejectedUsageCase("total-second", ResourceBudget(maxOutputTokens: 20, maxTotalOutputTokens: 23),
        2, true, budgetFailure: true)
    rejectedUsageCase("cost-first", ResourceBudget(maxOutputTokens: 20, maxCostMicros: 129),
        1, true, budgetFailure: true)
    rejectedUsageCase("cost-second", ResourceBudget(maxOutputTokens: 20, maxCostMicros: 157),
        2, true, budgetFailure: true)
    rejectedUsageResumeContract()
}

func rejectedUsageResumeContract(): Unit {
    let runs = MemoryRuns(failClaimBeforeCommitAt: 1)
    let model = RejectedReplyUsageModel()
    let catalog = ToolCatalog()
    let request = rejectedUsageRequest("resume", ResourceBudget(maxOutputTokens: 20), Some(rejectedUsagePricing()))
    let core = AgentCore(model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(resumeThreadRegistry("rejected-usage-resume"))
    )
    expect(core.start(request).isError() && model.calls == 0,
        "rejected usage resume fixture stops before provider dispatch")
    runs.failClaimBeforeCommitAt = 0
    let resumed = core.resume(request)
    expect(resumed.isError() && model.calls == 1 &&
        resumed.error().getOrThrow().code == "model.output_limited_before_decision",
        "resume validation rejection retains its root cause without a new retry")
    expectRejectedUsage(runs.find(request.runId).value().getOrThrow(),
        1, 100, 20, 5, 30, 10, Some(130),
        "resumed validation rejection also settles every observed usage bucket exactly once")
}
