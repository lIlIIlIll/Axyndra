package sdk_contract

import yjson_support.*

import yjson.*

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_embed.*
import agent_skills.*
import std.sync.*
import tool_runtime.*

main(): Int64 {
    if (!builderRequiresCanonicalDependencies()) { return 1 }
    if (!originPrecedenceAndSecretDescription()) { return 1 }
    if (!modelCapabilitiesAreValidated()) { return 1 }
    if (!structuredOutputAndVisionReachSdkResult()) { return 1 }
    if (!headlessRunStreamsTypedEvents()) { return 1 }
    if (!headlessOutputIsScopedToCurrentRun()) { return 1 }
    if (!jsonLinesApplyConservativeRedaction()) { return 1 }
    if (!explicitToolContextReachesSdkExecutor()) { return 1 }
    if (!explicitSkillStackReachesSdkModelLane()) { return 1 }
    if (!approvalContinuesThroughSameCore()) { return 1 }
    if (!cancellationPropagatesToProvider()) { return 1 }
    if (!blockingCancellationIsBoundedAndReasonPreserving()) { return 1 }
    if (!deadlineCancellationKeepsTimeoutSemantics()) { return 1 }
    if (!budgetFailureHasTypedExit()) { return 1 }
    println("sdk_contract: all contracts passed")
    0
}

func explicitSkillStackReachesSdkModelLane(): Bool {
    let provider = TextProvider("skill-aware")
    let descriptor = SkillDescriptor(
        "sdk-review", "sdk-review", "SDK review instructions", ["review"],
        "skill://sdk-review"
    )
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities()
    ).skillStack(SkillStackSnapshot([
        SkillActivation(descriptor, "Use the SDK skill contract.")
    ], [])).build().value().getOrThrow()
    let result = sdk.run("review")
    return expect(
        result.isOk() && provider.lastSystem.contains(
            "<active_skills trust=\"user_selected\" capabilities=\"none\">"
        ) &&
            provider.lastSystem.contains("Use the SDK skill contract.") &&
            sdk.configuration.skillStack.origin == Origin.Programmatic,
        "SDK freezes an explicit SkillStack into the Run model lane"
    )
}

func structuredOutputAndVisionReachSdkResult(): Bool {
    let schema = objectValue([
        ValueField("type", textValue("object")),
        ValueField("properties", objectValue([
            ValueField("answer", objectValue([
                ValueField("type", textValue("string"))
            ]))
        ])),
        ValueField("required", listValue([textValue("answer")]))
    ])
    let spec = StructuredOutputSpec("sdk_answer", schema)
    let provider = StructuredVisionProvider(objectValue([
        ValueField("answer", textValue("typed SDK result"))
    ]))
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        ModelCapabilities(
            toolCalling: true,
            vision: true,
            structuredOutput: true,
            promptCache: true,
            parallelToolCalling: true,
            contextWindowTokens: 4096,
            maxOutputTokens: 128
        ),
        budget: contractBudget(maxInputTokens: 2048)
    )
        .structuredOutput(spec).cachePolicy(ModelCachePolicy.StablePrefix)
        .parallelToolCalls(true)
        .build().value().getOrThrow()
    let sawStructuredEvent = AtomicBool(false)
    let result = sdk.runWithImages(
        "inspect image",
        [ModelImage(
            ModelImageSourceKind.Url,
            "https://example.invalid/image.png",
            detail: ModelImageDetail.Low
        )],
        eventSink: { event => match (event.payload) {
            case AgentEventPayload.StructuredOutputCompleted(_) =>
                sawStructuredEvent.store(true)
            case _ => ()
        }}
    )
    match (result) {
        case Result.Err(error) => expect(false, "structured SDK run failed: " + error.message)
        case Result.Ok(value) => expect(
            provider.sawImage && provider.sawStructuredOutput && provider.sawStablePrefixCache &&
                provider.sawParallelToolCalls &&
                provider.cacheKey != "" &&
                sawStructuredEvent.load() && value.structuredOutput.isSome() &&
                value.snapshot.structuredOutput.isSome() &&
                match (value.structuredOutput.getOrThrow().field("answer")) {
                    case Some(answer) => answer.text == "typed SDK result"
                    case None => false
                },
            "SDK carries image input, parallel tool negotiation, cache policy, schema request, typed event, and structured result"
        )
    }
}

func builderRequiresCanonicalDependencies(): Bool {
    expect(
        errorCode(AgentBuilder().build()) == "sdk.builder_missing_dependency",
        "builder rejects an incomplete runtime instead of inventing a second product core"
    )
}

func originPrecedenceAndSecretDescription(): Bool {
    let selected = mergeOriginValues<String>([
        OriginValue<String>("model", "default-model", Origin.Default),
        OriginValue<String>("model", "file-model", Origin.File),
        OriginValue<String>("model", "environment-model", Origin.Environment),
        OriginValue<String>("model", "cli-model", Origin.Cli),
        OriginValue<String>("model", "programmatic-model", Origin.Programmatic),
        // A lower layer applied late must not win.
        OriginValue<String>("model", "late-file-model", Origin.File)
    ])
    let secret = OriginValue<String>(
        "api_key",
        "contract-super-secret",
        Origin.Environment,
        secret: true
    ).merged(OriginValue<String>(
        "api_key",
        "lower-file-secret",
        Origin.File
    ))
    expect(
        selected.value == "programmatic-model" && selected.origin == Origin.Programmatic &&
            secret.describe({ value => value }).contains("[REDACTED]") &&
            !secret.describe({ value => value }).contains("contract-super-secret") &&
            !secret.describe({ value => value }).contains("lower-file-secret"),
        "configuration precedence is explicit and secret descriptions never reveal values"
    )
}

func modelCapabilitiesAreValidated(): Bool {
    let catalog = ToolCatalog()
    let tool = DemoTool()
    let registered = catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "read_demo",
                "read a demo value",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        tool
    )
    if (registered.isError()) { return expect(false, "tool registration should succeed") }
    let noTools = configuredBuilder(
        TextProvider("never"),
        catalog,
        ModelCapabilities(
            contextWindowTokens: 1024,
            maxOutputTokens: 128
        ),
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ).build()
    let tooSmall = configuredBuilder(
        TextProvider("never"),
        ToolCatalog(),
        ModelCapabilities(
            contextWindowTokens: 200,
            maxOutputTokens: 64
        ),
        budget: contractBudget(maxInputTokens: 180, maxOutputTokens: 64)
    ).build()
    expect(
        errorCode(noTools) == "model.capability_unsupported" &&
            errorCode(tooSmall) == "sdk.model_context_limit",
        "builder validates tool and token requirements against ModelCapabilities"
    )
}

func headlessRunStreamsTypedEvents(): Bool {
    let provider = TextProvider("你好 SDK")
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities(),
        modelName: "file-model",
        modelOrigin: Origin.File
    ).build().value().getOrThrow()
    let result = HeadlessRunner(sdk).run("say hello")
    let description = sdk.configuration.describe()
    let completed = expect(
        result.status == HeadlessStatus.Completed && result.exitCode == 0 &&
            result.text == "你好 SDK",
        "headless runner returns typed success and UTF-8 text"
    )
    let events = expect(
        result.jsonEvents.contains("\"type\":\"agent_event\"") &&
            result.jsonEvents.contains("\"kind\":\"model\"") &&
            result.jsonEvents.contains("你好 SDK"),
        "headless runner emits typed UTF-8 JSONL events"
    )
    let providerContract = expect(
        provider.calls == 1 && provider.lastModel == "file-model" &&
            provider.lastSystem.contains("sdk-base-contract") &&
            sdk.configuration.model.origin == Origin.File,
        "headless runner preserves provider configuration"
    )
    let metadata = expect(
        description.contains("model=file-model (origin=file)") &&
            description.contains("prompt=[REDACTED]") &&
            !description.contains("sdk-base-contract"),
        "headless configuration metadata remains secret-safe"
    )
    completed && events && providerContract && metadata
}

func headlessOutputIsScopedToCurrentRun(): Bool {
    let provider = SuccessThenFailureProvider("first run answer")
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities()
    ).build().value().getOrThrow()
    let headless = HeadlessRunner(sdk)
    let first = headless.run("succeed once")
    let second = headless.run("fail now")
    expect(
        first.status == HeadlessStatus.Completed &&
            first.text == "first run answer" &&
            second.status == HeadlessStatus.Failed && second.text == "" &&
            !second.text.contains("first run answer"),
        "headless fallback only reads assistant text created by the current invocation"
    )
}

func jsonLinesApplyConservativeRedaction(): Bool {
    let callerSawRawSecret = AtomicBool(false)
    let sink = JsonAgentEventSink(redact: { value =>
        if (value.contains("plain-password") || value.contains("plain-token") ||
            value.contains("sk-contract-very-secret") ||
            value.contains("nested-api-key") ||
            value.contains("bearer-contract-secret")) {
            callerSawRawSecret.store(true)
        }
        value.replace("caller-private", "[CALLER-REDACTED]")
    })
    sink.accept(AgentEvent(
        EventMeta(1, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.Audit("sdk.redaction", objectValue([
            ValueField("password", textValue("plain-password")),
            ValueField("message", textValue(
                "token=plain-token sk-contract-very-secret caller-private"
            )),
            ValueField("input_tokens", integerValue(7)),
            ValueField("nested", objectValue([
                ValueField("api_key", textValue("nested-api-key"))
            ]))
        ]))
    ))
    sink.acceptError(AgentError(
        AgentErrorKind.Authentication,
        "provider.auth",
        "Authorization: Bearer bearer-contract-secret"
    ))
    sink.accept(AgentEvent(
        EventMeta(2, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TextDelta("prefix sk-split-ULTRA")
    ))
    sink.accept(AgentEvent(
        EventMeta(3, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TextDelta("-PRIVATE-VALUE suffix\nAuthorization: Bear")
    ))
    sink.accept(AgentEvent(
        EventMeta(4, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TextDelta("er SPLIT-HEADER-VALUE\nsafe-visible\n")
    ))
    sink.accept(AgentEvent(
        EventMeta(5, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TextDelta(
            "-----BEGIN PRIVATE KEY-----\nPEM-SPLIT-"
        )
    ))
    sink.accept(AgentEvent(
        EventMeta(6, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TextDelta(
            "PRIVATE-BODY\n-----END PRIVATE KEY-----\n"
        )
    ))
    sink.accept(AgentEvent(
        EventMeta(7, TraceId("sdk-redaction-trace"), RunId("sdk-redaction-run")),
        AgentEventPayload.TurnCompleted(TurnId("sdk-redaction-turn"))
    ))
    let lines = sink.jsonLines()
    expect(
        lines.contains("[REDACTED]") &&
            lines.contains("[CALLER-REDACTED]") &&
            !callerSawRawSecret.load() &&
            !lines.contains("plain-password") &&
            !lines.contains("plain-token") &&
            !lines.contains("sk-contract-very-secret") &&
            !lines.contains("nested-api-key") &&
            !lines.contains("bearer-contract-secret") &&
            !lines.contains("SPLIT-HEADER-VALUE") &&
            !lines.contains("ULTRA-PRIVATE-VALUE") &&
            !lines.contains("PEM-SPLIT-PRIVATE-BODY") &&
            lines.contains("\"input_tokens\":7") &&
            lines.contains("safe-visible") &&
            !lines.contains("caller-private"),
        "JSONL applies recursive and cross-delta secret redaction before streaming"
    )
}

func explicitToolContextReachesSdkExecutor(): Bool {
    let provider = ToolContextProvider()
    let catalog = ToolCatalog()
    let tool = ToolContextCaptureTool()
    if (catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "context_probe",
                "capture SDK tool context",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        tool
    ).isError()) {
        return expect(false, "SDK tool context fixture registration should succeed")
    }
    let context = ToolContextDescriptor(
        workspaceRoot: "/sdk/explicit-workspace",
        cwd: "/sdk/explicit-workspace/src",
        environment: ToolEnvironmentView(entries: [
            ToolEnvironmentEntry("SDK_VISIBLE", "sdk-private-value")
        ]),
        services: ToolServiceView(descriptors: [
            ToolServiceDescriptor(ToolServiceKind.Custom, "sdk-context-service", version: "1")
        ])
    )
    let sdk = configuredBuilder(
        provider,
        catalog,
        toolCapabilities(),
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ).toolContext(context).build().value().getOrThrow()
    let result = sdk.run("inspect explicit tool context")
    let description = sdk.configuration.describe()
    expect(
        result.isOk() && result.value().getOrThrow().status == SdkRunStatus.Completed &&
            provider.calls == 2 && tool.calls == 1 && tool.valid &&
            sdk.configuration.toolContext.origin == Origin.Programmatic &&
            description.contains("env_names=SDK_VISIBLE") &&
            !description.contains("sdk-private-value") &&
            !description.contains("/sdk/explicit-workspace"),
        "SDK forwards only an explicit ToolContextDescriptor and describes names without leaking values"
    )
}

func approvalContinuesThroughSameCore(): Bool {
    let provider = ApprovalProvider()
    let catalog = ToolCatalog()
    let tool = DemoTool()
    let registered = catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "write_demo",
                "write a demo value",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        tool
    )
    if (registered.isError()) { return expect(false, "approval tool registration should succeed") }
    let sdk = configuredBuilder(
        provider,
        catalog,
        toolCapabilities(),
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk)
    ).build().value().getOrThrow()
    let first = sdk.run("write it")
    let firstValue = match (first) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "approval run failed: " + error.message)
    }
    let pending = match (firstValue.pending) {
        case Some(value) => value
        case None => return expect(false, "approval run should expose a continuation")
    }
    let resumed = HeadlessRunner(sdk).continueApproval(pending, ApprovalDecision.Approve)
    expect(
        firstValue.status == SdkRunStatus.AwaitingApproval &&
            resumed.status == HeadlessStatus.Completed && resumed.text == "approved" &&
            provider.calls == 2 && tool.calls == 1 &&
            resumed.run.isSome() && resumed.run.getOrThrow().snapshot.runId.value ==
                firstValue.snapshot.runId.value,
        "continueApproval resumes the durable pending operation through the same AgentCore"
    )
}

func cancellationPropagatesToProvider(): Bool {
    let cancellation = CancellationSource()
    let provider = SelfCancellingProvider(cancellation)
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities()
    ).build().value().getOrThrow()
    let result = HeadlessRunner(sdk).run("cancel me", cancellation.token)
    cancellation.close()
    expect(
        result.status == HeadlessStatus.Cancelled && result.exitCode == 130 &&
            result.error.isSome() && result.error.getOrThrow().kind == AgentErrorKind.Cancelled &&
            provider.executeCalls == 1 && provider.cancelCalls > 0,
        "CancellationToken reaches the active provider and maps to a typed headless result"
    )
}

func blockingCancellationIsBoundedAndReasonPreserving(): Bool {
    let cancellation = CancellationSource()
    let conversations = BlockingCancellationProbe()
    let provider = BlockingCancellationProvider(cancellation, conversations)
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities()
    ).build().value().getOrThrow()
    let future = spawn {
        HeadlessRunner(sdk).run("cancel without blocking", cancellation.token)
    }
    waitForCondition(
        { => conversations.cancellationReadEntered() },
        2000
    )
    let settledBeforeRelease = waitForFuture(future, 500)
    conversations.releaseCancellationRead()
    let settledAfterRelease = waitForFuture(future, 4000)
    if (!settledAfterRelease) {
        cancellation.close()
        return expect(false, "SDK cancellation run did not settle after releasing the fake")
    }
    let result = future.get()
    cancellation.close()
    expect(
        settledBeforeRelease && settledAfterRelease &&
            result.status == HeadlessStatus.Cancelled &&
            result.error.isSome() &&
            result.error.getOrThrow().code == "contract.blocking_cancel" &&
            result.error.getOrThrow().message == "preserve this cancellation reason" &&
            result.error.getOrThrow().field("reason_kind") == Some("user"),
        "SDK cancellation returns without waiting for a blocked external cancel and preserves its reason"
    )
}

func deadlineCancellationKeepsTimeoutSemantics(): Bool {
    let expired = CancellationSource(deadlineMillis: 1)
    let provider = TextProvider("must not execute")
    let sdk = configuredBuilder(
        provider,
        ToolCatalog(),
        textCapabilities()
    ).build().value().getOrThrow()
    let result = HeadlessRunner(sdk).run("expired", expired.token)
    expired.close()
    expect(
        result.status == HeadlessStatus.TimedOut && result.exitCode == 124 &&
            result.error.isSome() &&
            result.error.getOrThrow().kind == AgentErrorKind.Timeout &&
            result.error.getOrThrow().code == "run.deadline_exceeded" &&
            result.error.getOrThrow().field("reason_kind") == Some("deadline") &&
            provider.calls == 0,
        "an inherited deadline remains a timeout instead of degrading to generic cancellation"
    )
}

func budgetFailureHasTypedExit(): Bool {
    let provider = LoopingToolProvider()
    let catalog = ToolCatalog()
    let tool = DemoTool()
    let registered = catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "read_demo",
                "read a demo value",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        tool
    )
    if (registered.isError()) { return expect(false, "budget tool registration should succeed") }
    let sdk = configuredBuilder(
        provider,
        catalog,
        toolCapabilities(),
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: contractBudget(maxTurns: 1, maxToolCalls: 4),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    ).build().value().getOrThrow()
    let result = HeadlessRunner(sdk).run("keep reading")
    expect(
        result.status == HeadlessStatus.BudgetExceeded && result.exitCode == 75 &&
            result.error.isSome() && result.error.getOrThrow().kind == AgentErrorKind.BudgetExceeded &&
            result.error.getOrThrow().code == "budget.turns_exceeded" &&
            result.error.getOrThrow().field("dimension") == Some("turns") &&
            result.error.getOrThrow().field("limit") == Some("1") &&
            result.error.getOrThrow().field("observed") == Some("2") &&
            provider.calls == 1 && tool.calls == 1,
        "execution budget failures preserve their type and stable headless exit mapping"
    )
}

func configuredBuilder(
    provider: ModelPort,
    catalog: ToolCatalog,
    modelCapabilities: ModelCapabilities,
    modelName!: String = "contract-model",
    modelOrigin!: Origin = Origin.Programmatic,
    capabilities!: CapabilitySet = CapabilitySet(),
    budget!: ResourceBudget = contractBudget(),
    policy!: CapabilityPolicy = DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
): AgentBuilder {
    AgentBuilder()
        .provider(provider, label: "fake-provider", origin: Origin.Programmatic)
        .model(modelName, modelCapabilities, origin: modelOrigin)
        .tools(catalog, label: "fake-tools", origin: Origin.Programmatic)
        .session(SessionId("sdk-contract-session"))
        .runRepository(FakeRunStore(), label: "fake-run-store")
        .policy(policy, label: "contract-policy")
        .budget(budget)
        .prompt(contractPrompt())
        .operations(FakeOperationStore())
        .audit(FakeAudit())
        .ids(FakeIds())
        .capabilities(capabilities)
        .thinking(ThinkingLevel.Off)
}

func contractPrompt(): PromptBuilder {
    PromptBuilder().add(PromptSection(
        PromptSectionKind.Base,
        PromptTrust.System,
        PromptStability.Stable,
        "sdk-contract",
        "1",
        "sdk-base-contract"
    ))
}

func contractBudget(
    maxInputTokens!: Int64 = 256,
    maxOutputTokens!: Int64 = 64,
    maxTurns!: Int64 = 4,
    maxToolCalls!: Int64 = 8
): ResourceBudget {
    ResourceBudget(
        maxInputTokens: maxInputTokens,
        maxOutputTokens: maxOutputTokens,
        maxModelRequests: 8,
        maxTurns: maxTurns,
        maxToolCalls: maxToolCalls,
        maxWallMillis: 10000,
        maxIdleMillis: 2000,
        maxConcurrentTools: 1
    )
}

func textCapabilities(): ModelCapabilities {
    ModelCapabilities(
        contextWindowTokens: 1024,
        maxOutputTokens: 128
    )
}

func toolCapabilities(): ModelCapabilities {
    ModelCapabilities(
        toolCalling: true,
        contextWindowTokens: 1024,
        maxOutputTokens: 128
    )
}

func errorCode<T>(result: Result<T>): String {
    match (result) {
        case Result.Ok(_) => ""
        case Result.Err(error) => error.code
    }
}

func expect(condition: Bool, message: String): Bool {
    if (condition) {
        println("PASS " + message)
        true
    } else {
        println("FAIL " + message)
        false
    }
}

func waitForCondition(condition: () -> Bool, maxMillis: Int64): Bool {
    var waited: Int64 = 0
    while (!condition() && waited < maxMillis) {
        sleep(Duration.millisecond)
        waited += 1
    }
    condition()
}

func waitForFuture<T>(future: Future<T>, maxMillis: Int64): Bool {
    var waited: Int64 = 0
    while (future.tryGet().isNone() && waited < maxMillis) {
        sleep(Duration.millisecond)
        waited += 1
    }
    future.tryGet().isSome()
}
