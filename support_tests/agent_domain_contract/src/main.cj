package agent_domain_contract

import agent_domain.*

main(): Int64 {
    let ok: Result<String> = Result.Ok("ready")
    expect(ok.isOk(), "Result.Ok is observable")
    expect(ok.value().getOrThrow() == "ready", "Result.Ok exposes its value")
    let error = AgentError(
        AgentErrorKind.Timeout,
        "model.timeout",
        "model request timed out",
        retryable: true,
        fallbackAllowed: true,
        fields: [ErrorField("provider", "fixture")]
    )
    let failed: Result<String> = Result.Err(error)
    expect(failed.isError(), "Result.Err is observable")
    expect(
        failed.error().getOrThrow().code == "model.timeout",
        "Result.Err exposes its structured error"
    )
    expect(error.field("provider") == Some("fixture"),
           "AgentError exposes structured fields")

    let nested = objectValue([
        ValueField("name", textValue("echo")),
        ValueField("enabled", boolValue(true)),
        ValueField("limits", listValue([integerValue(1), integerValue(2)]))
    ])
    expect(nested.kind == ValueKind.Object, "structured object value")
    expect(match (nested.field("name")) {
        case Some(value) => value.text == "echo"
        case None => false
    }, "structured value lookup")

    let capabilities = CapabilitySet(values: [
        Capability(
            CapabilityKind.WorkspaceRead,
            resource: "src/main.cj"
        ),
        Capability(CapabilityKind.Delegate)
    ])
    expect(capabilities.allows(
        CapabilityKind.WorkspaceRead, resource: "src/main.cj"
    ), "resource capability")
    expect(!capabilities.allows(
        CapabilityKind.WorkspaceWrite, resource: "src/main.cj"
    ), "missing capability is denied")

    let budget = ResourceBudget(maxTurns: 3, maxChildren: 1)
    expect(budget.maxTurns == 3 && budget.maxChildren == 1,
           "resource budget")
    expect(rejects({ => ResourceBudget(maxTurns: 0) }),
           "invalid budget rejected")

    let runId = RunId("run-1")
    let sessionId = SessionId("session-1")
    let snapshot = RunSnapshot(
        runId, sessionId, RunState.Running, sequence: 2
    )
    expect(snapshot.status == RunState.Running, "run snapshot")
    let event = AgentEvent(
        EventMeta(1, TraceId("agent-domain-contract"), runId),
        AgentEventPayload.RunStarted
    )
    let page = EventPage([event], 2)
    expect(page.events.size == 1 && page.nextSequence == 2,
           "typed event page")

    let operationId = OperationId("operation-1")
    let operation = OperationRecord(
        operationId,
        runId,
        OperationStatus.Prepared,
        Capability(
            CapabilityKind.WorkspaceWrite,
            resource: "notes/demo.txt"
        ),
        "digest"
    )
    expect(operation.status == OperationStatus.Prepared,
           "operation state")
    let receipt = OperationReceipt(
        operationId, true,
        objectValue([ValueField("changed", boolValue(true))])
    )
    expect(receipt.committed, "operation receipt")

    let partialBudget = ThinkingCapabilities(
        ThinkingControlMode.Budget,
        supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium, ThinkingLevel.High]
    )
    expect(partialBudget.budgetTiers.size == 3 &&
        partialBudget.budgetFor(ThinkingLevel.Low) == Some(2048) &&
        partialBudget.budgetFor(ThinkingLevel.Medium) == Some(8192) &&
        partialBudget.budgetFor(ThinkingLevel.High) == Some(16384),
        "budget defaults project over exactly the supported levels")
    expect(rejects({ => ThinkingCapabilities(
        ThinkingControlMode.Budget,
        supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium],
        budgetTiers: [
            ThinkingBudgetTier(ThinkingLevel.Low, 2048),
            ThinkingBudgetTier(ThinkingLevel.High, 16384)
        ]
    ) }), "budget tiers cannot contain unsupported levels")
    expect(rejects({ => ThinkingCapabilities(
        ThinkingControlMode.Budget,
        supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium],
        budgetTiers: [
            ThinkingBudgetTier(ThinkingLevel.Low, 8192),
            ThinkingBudgetTier(ThinkingLevel.Medium, 2048)
        ]
    ) }), "budget tiers are monotonic non-decreasing")

    let budgetSnapshot = ModelExecutionCapabilitiesSnapshot(
        "budget-model",
        ThinkingCapabilities(
            ThinkingControlMode.Budget,
            supportedLevels: canonicalNonOffThinkingLevels()
        ),
        16384,
        endpointMaxOutputTokens: Some(12000)
    )
    let requested = RequestedModelPolicy(
        ThinkingLevel.High,
        RequestOutputBudget(32768, minVisibleResponseTokens: 1024)
    )
    let resolved = resolveModelAttemptPolicy(
        AttemptPolicyInput(requested, budgetSnapshot)
    ).value().getOrThrow()
    expect(resolved.output.effectiveWireLimit == 12000 &&
        isThinking(resolved.thinking.effective, ThinkingLevel.Medium) &&
        resolved.decisionReserveTokens == 1024,
        "output limits and available thinking budget resolve independently")
    expect(resolved.output.constraints.size == 2 &&
        resolved.thinking.constraints.size == 1,
        "only effective constraints are recorded in canonical order")

    let toggle = resolveModelAttemptPolicy(AttemptPolicyInput(
        RequestedModelPolicy(ThinkingLevel.Max, RequestOutputBudget(4096)),
        ModelExecutionCapabilitiesSnapshot(
            "toggle-model", ThinkingCapabilities(ThinkingControlMode.Toggle), 4096
        )
    )).value().getOrThrow()
    expect(isThinking(toggle.thinking.effective, ThinkingLevel.Max),
        "toggle accepts non-Off intent without inventing effort granularity")

    let insufficient = resolveModelAttemptPolicy(AttemptPolicyInput(
        RequestedModelPolicy(
            ThinkingLevel.Low,
            RequestOutputBudget(1500, minVisibleResponseTokens: 1024)
        ),
        budgetSnapshot
    ))
    expect(insufficient.isError() &&
        insufficient.error().getOrThrow().code == "model.thinking_policy_incompatible",
        "budget insufficiency fails before provider I/O instead of silently disabling thinking")

    let effortSnapshot = ModelExecutionCapabilitiesSnapshot(
        "effort-model",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: [ThinkingLevel.Low, ThinkingLevel.High, ThinkingLevel.Max]
        ),
        4096
    )
    let recoveredHigh = resolveModelAttemptPolicy(AttemptPolicyInput(
        RequestedModelPolicy(
            ThinkingLevel.Max,
            RequestOutputBudget(4096),
            userRequestedThinking: Some(ThinkingLevel.Max),
            thinkingSource: ThinkingPreferenceSource.ExplicitUser
        ),
        effortSnapshot,
        recoveryCeiling: nextLowerThinkingCeiling(effortSnapshot, ThinkingLevel.Max)
    )).value().getOrThrow()
    let recoveredOff = resolveModelAttemptPolicy(AttemptPolicyInput(
        RequestedModelPolicy(ThinkingLevel.Low, RequestOutputBudget(4096)),
        effortSnapshot,
        recoveryCeiling: Some(ThinkingLevel.Off)
    )).value().getOrThrow()
    expect(recoveredHigh.thinking.effective == ThinkingLevel.High &&
        recoveredHigh.userRequestedThinking == Some(ThinkingLevel.Max) &&
        recoveredHigh.thinkingSource == ThinkingPreferenceSource.ExplicitUser &&
        recoveredOff.thinking.effective == ThinkingLevel.Off &&
        recoveredOff.thinking.budgetTokens.isNone(),
        "recovery ceiling follows real supported levels without rewriting requested policy")
    expect(rejects({ => ModelUsage(outputTokens: 3, reasoningTokens: 4) }),
        "reasoning usage is a subset of output usage and cannot be double counted")
    expect(rejects({ => ModelUsage(
        outputTokens: 3,
        source: ModelUsageSource.ProviderFinal
    ) }), "provider usage source requires typed terminal evidence")
    let evidencedUsage = ModelUsage(
        outputTokens: 3,
        reasoningTokens: 2,
        source: ModelUsageSource.ProviderStreamFinal,
        evidence: Some(ModelUsageEvidence(
            "openai_chat_completions", "finish_reason", providerResponseId: "response-1"
        ))
    )
    expect(evidencedUsage.reasoningTokens == 2 &&
        evidencedUsage.evidence.getOrThrow().providerResponseId == "response-1",
        "provider usage records source and terminal evidence without double counting reasoning")

    let repeated = resolveModelAttemptPolicy(
        AttemptPolicyInput(requested, budgetSnapshot)
    ).value().getOrThrow()
    expect(canonicalResolvedModelRequestPolicy(resolved) ==
        canonicalResolvedModelRequestPolicy(repeated),
        "resolver v1 has byte-identical canonical output for identical normalized input")
    expect(budgetSnapshot.capabilityFingerprint.size == 64,
        "capability snapshot materializes a SHA-256 fingerprint")
    expect(rejects({ => ModelExecutionCapabilitiesSnapshot(
        "budget-model", budgetSnapshot.thinking, 16384,
        endpointMaxOutputTokens: Some(12000), capabilityFingerprint: "corrupt"
    ) }), "snapshot fingerprint validates only its persisted normalized payload")
    println("agent_domain contract passed")
    0
}

func isThinking(left: ThinkingLevel, right: ThinkingLevel): Bool {
    thinkingRank(left) == thinkingRank(right)
}

func thinkingRank(value: ThinkingLevel): Int64 {
    match (value) {
        case ThinkingLevel.Off => 0
        case ThinkingLevel.Minimal => 1
        case ThinkingLevel.Low => 2
        case ThinkingLevel.Medium => 3
        case ThinkingLevel.High => 4
        case ThinkingLevel.XHigh => 5
        case ThinkingLevel.Max => 6
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

func rejects(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}
