package agent_embed

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_skills.*
import std.collection.*
import std.deriving.*
import std.sync.*
import tool_runtime.*

class ProviderBinding {
    let port: ModelPort
    let label: String

    init(port: ModelPort, label: String) {
        if (label.trimAscii() == "") {
            throw IllegalArgumentException("provider label must not be empty")
        }
        this.port = port
        this.label = label.trimAscii()
    }
}

class ModelBinding {
    let name: String
    let capabilities: ModelCapabilities

    init(name: String, capabilities: ModelCapabilities) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("model name must not be empty")
        }
        this.name = name.trimAscii()
        this.capabilities = capabilities
    }
}

class ToolsBinding {
    let catalog: ToolCatalog
    let label: String

    init(catalog: ToolCatalog, label: String) {
        if (label.trimAscii() == "") {
            throw IllegalArgumentException("tool catalog label must not be empty")
        }
        this.catalog = catalog
        this.label = label.trimAscii()
    }
}

class SessionBinding {
    let id: SessionId

    init(id: SessionId) {
        this.id = id
    }
}

class RunRepositoryBinding {
    let repository: RunRepository
    let label: String

    init(repository: RunRepository, label: String) {
        if (label.trimAscii() == "") {
            throw IllegalArgumentException("run repository label must not be empty")
        }
        this.repository = repository
        this.label = label.trimAscii()
    }
}

class PolicyBinding {
    let policy: CapabilityPolicy
    let label: String

    init(policy: CapabilityPolicy, label: String) {
        if (label.trimAscii() == "") {
            throw IllegalArgumentException("policy label must not be empty")
        }
        this.policy = policy
        this.label = label.trimAscii()
    }
}

public class AgentBuilder {
    private var providerValue: ?OriginValue<ProviderBinding> = None
    private var modelValue: ?OriginValue<ModelBinding> = None
    private var toolsValue: ?OriginValue<ToolsBinding> = None
    private var sessionValue: ?OriginValue<SessionBinding> = None
    private var runsValue: ?OriginValue<RunRepositoryBinding> = None
    private var policyValue: ?OriginValue<PolicyBinding> = None
    private var budgetValue: ?OriginValue<ResourceBudget> = None
    private var promptValue: ?OriginValue<PromptBuild> = None
    private var operationsValue: ?OperationRepository = None
    private var auditValue: ?AuditPort = None
    private var idsValue: ?IdGenerator = None
    private var permissionsValue: ?PermissionRepository = None
    private var pricingValue: ?ModelPricing = None
    private var thinkingValue = OriginValue<ThinkingLevel>("thinking", ThinkingLevel.Off, Origin.Default)
    private var capabilitiesValue = OriginValue<CapabilitySet>("capabilities", CapabilitySet(), Origin.Default)
    private var autoRetryValue = OriginValue<Bool>("auto_retry", true, Origin.Default)
    private var serviceTierValue = OriginValue<String>("service_tier", "", Origin.Default)
    private var structuredOutputValue = OriginValue<?StructuredOutputSpec>(
        "structured_output",
        None,
        Origin.Default
    )
    private var cachePolicyValue = OriginValue<ModelCachePolicy>(
        "cache_policy",
        ModelCachePolicy.Default,
        Origin.Default
    )
    private var parallelToolCallsValue = OriginValue<Bool>(
        "parallel_tool_calls",
        false,
        Origin.Default
    )
    private var toolContextValue = OriginValue<ToolContextDescriptor>(
        "tool_context",
        ToolContextDescriptor(),
        Origin.Default
    )
    private var skillStackValue = OriginValue<SkillStackSnapshot>(
        "skill_stack",
        SkillStackSnapshot([], []),
        Origin.Default
    )

    public init() {}

    public func provider(
        value: ModelPort,
        label!: String = "custom",
        origin!: Origin = Origin.Programmatic,
        secretLabel!: Bool = false
    ): AgentBuilder {
        providerValue = Some(selectOrigin(
            providerValue,
            OriginValue<ProviderBinding>(
                "provider",
                ProviderBinding(value, label),
                origin,
                secret: secretLabel
            )
        ))
        this
    }

    public func model(
        name: String,
        capabilities: ModelCapabilities,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        modelValue = Some(selectOrigin(
            modelValue,
            OriginValue<ModelBinding>("model", ModelBinding(name, capabilities), origin)
        ))
        this
    }

    public func tools(
        catalog: ToolCatalog,
        label!: String = "catalog",
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        toolsValue = Some(selectOrigin(
            toolsValue,
            OriginValue<ToolsBinding>("tools", ToolsBinding(catalog, label), origin)
        ))
        this
    }

    public func session(
        id: SessionId,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        sessionValue = Some(selectOrigin(
            sessionValue,
            OriginValue<SessionBinding>("session", SessionBinding(id), origin)
        ))
        this
    }

    public func runRepository(
        repository: RunRepository,
        label!: String = "run-repository",
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        runsValue = Some(selectOrigin(
            runsValue,
            OriginValue<RunRepositoryBinding>(
                "run_repository",
                RunRepositoryBinding(repository, label),
                origin
            )
        ))
        this
    }

    public func policy(
        policy: CapabilityPolicy,
        label!: String = "capability-policy",
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        policyValue = Some(selectOrigin(
            policyValue,
            OriginValue<PolicyBinding>("policy", PolicyBinding(policy, label), origin)
        ))
        this
    }

    public func budget(
        budget: ResourceBudget,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        budgetValue = Some(selectOrigin(
            budgetValue,
            OriginValue<ResourceBudget>("budget", budget, origin)
        ))
        this
    }

    public func prompt(
        prompt: PromptBuilder,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        promptValue = Some(selectOrigin(
            promptValue,
            OriginValue<PromptBuild>("prompt", prompt.build(), origin, secret: true)
        ))
        this
    }

    public func operations(repository: OperationRepository): AgentBuilder {
        operationsValue = Some(repository)
        this
    }

    public func audit(port: AuditPort): AgentBuilder {
        auditValue = Some(port)
        this
    }

    public func ids(generator: IdGenerator): AgentBuilder {
        idsValue = Some(generator)
        this
    }

    public func permissions(repository: PermissionRepository): AgentBuilder {
        permissionsValue = Some(repository)
        this
    }

    public func thinking(
        value: ThinkingLevel,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        thinkingValue = thinkingValue.merged(OriginValue<ThinkingLevel>("thinking", value, origin))
        this
    }

    public func capabilities(
        value: CapabilitySet,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        capabilitiesValue = capabilitiesValue.merged(OriginValue<CapabilitySet>("capabilities", value, origin))
        this
    }

    public func autoRetry(
        value: Bool,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        autoRetryValue = autoRetryValue.merged(OriginValue<Bool>("auto_retry", value, origin))
        this
    }

    public func serviceTier(
        value: String,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        serviceTierValue = serviceTierValue.merged(OriginValue<String>("service_tier", value.trimAscii(), origin))
        this
    }

    public func pricing(value: ModelPricing): AgentBuilder {
        pricingValue = Some(value)
        this
    }

    public func structuredOutput(
        value: StructuredOutputSpec,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        structuredOutputValue = structuredOutputValue.merged(
            OriginValue<?StructuredOutputSpec>(
                "structured_output",
                Some(value),
                origin
            )
        )
        this
    }

    public func clearStructuredOutput(
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        structuredOutputValue = structuredOutputValue.merged(
            OriginValue<?StructuredOutputSpec>("structured_output", None, origin)
        )
        this
    }

    public func cachePolicy(
        value: ModelCachePolicy,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        cachePolicyValue = cachePolicyValue.merged(
            OriginValue<ModelCachePolicy>("cache_policy", value, origin)
        )
        this
    }

    public func parallelToolCalls(
        value: Bool,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        parallelToolCallsValue = parallelToolCallsValue.merged(
            OriginValue<Bool>("parallel_tool_calls", value, origin)
        )
        this
    }

    // The SDK never samples the host environment. Embedders must provide an
    // already-filtered view and explicit typed service descriptors.
    public func toolContext(
        value: ToolContextDescriptor,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        toolContextValue = toolContextValue.merged(
            OriginValue<ToolContextDescriptor>(
                "tool_context",
                ToolContextDescriptor(
                    workspaceRoot: value.workspaceRoot,
                    cwd: value.cwd,
                    environment: value.environment,
                    services: value.services
                ),
                origin
            )
        )
        this
    }

    public func skillStack(
        value: SkillStackSnapshot,
        origin!: Origin = Origin.Programmatic
    ): AgentBuilder {
        skillStackValue = skillStackValue.merged(
            OriginValue<SkillStackSnapshot>("skill_stack", value, origin)
        )
        this
    }

    public func build(): Result<AgentSdk> {
        let missing = missingDependencies()
        if (!missing.isEmpty()) {
            return sdkError<AgentSdk>(
                AgentErrorKind.Configuration,
                "sdk.builder_missing_dependency",
                "AgentBuilder is missing required dependencies: " + joinStrings(missing, ", "),
                fields: [ErrorField("missing", joinStrings(missing, ","))]
            )
        }
        let provider = providerValue.getOrThrow()
        let model = modelValue.getOrThrow()
        let tools = toolsValue.getOrThrow()
        let session = sessionValue.getOrThrow()
        let runs = runsValue.getOrThrow()
        let policy = policyValue.getOrThrow()
        let budget = budgetValue.getOrThrow()
        let prompt = promptValue.getOrThrow()
        let operations = operationsValue.getOrThrow()
        let audit = auditValue.getOrThrow()
        let ids = idsValue.getOrThrow()
        if (prompt.value.sections.isEmpty() || prompt.value.text.trimAscii() == "") {
            return sdkError<AgentSdk>(
                AgentErrorKind.Configuration,
                "sdk.prompt_empty",
                "SDK prompt configuration must contain at least one non-empty section"
            )
        }
        match (validateModelConfiguration(
            model.value,
            tools.value.catalog,
            capabilitiesValue.value,
            thinkingValue.value,
            budget.value,
            prompt.value.text,
            structuredOutputValue.value,
            cachePolicyValue.value,
            prompt.value.stablePrefixHash,
            parallelToolCallsValue.value
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let validatedProvider = CapabilityValidatedModelPort(
            provider.value.port,
            model.value.capabilities
        )
        let pipeline = ToolPipeline(
            tools.value.catalog,
            operations,
            audit,
            ids,
            policy: policy.value.policy,
            permissions: match (permissionsValue) {
                case Some(value) => value
                case None => MemoryPermissionRepository()
            }
        )
        let threadRuntimes = InMemoryThreadRuntimeRegistry(
            ContextProjector("agent-sdk-v1", ConservativeThreadTokenEstimator()),
            { => agentUtcMillis() }
        )
        let core = AgentCore(
            validatedProvider,
            runs.value.repository,
            pipeline,
            tools.value.catalog,
            threadRuntimes: Some(threadRuntimes)
        )
        let configuration = AgentSdkConfiguration(
            stringOrigin(provider, provider.value.label),
            stringOrigin(model, model.value.name),
            stringOrigin(tools, tools.value.label),
            stringOrigin(session, session.value.id.value),
            stringOrigin(runs, runs.value.label),
            stringOrigin(policy, policy.value.label),
            budget,
            prompt,
            thinkingValue,
            capabilitiesValue,
            autoRetryValue,
            serviceTierValue,
            structuredOutputValue,
            cachePolicyValue,
            parallelToolCallsValue,
            toolContextValue,
            skillStackValue
        )
        Result.Ok(AgentSdk(
            core,
            ids,
            session.value,
            threadRuntimes,
            configuration,
            pricing: pricingValue
        ))
    }

    private func missingDependencies(): Array<String> {
        let values = ArrayList<String>()
        if (providerValue.isNone()) { values.add("provider") }
        if (modelValue.isNone()) { values.add("model") }
        if (toolsValue.isNone()) { values.add("tools") }
        if (sessionValue.isNone()) { values.add("session") }
        if (runsValue.isNone()) { values.add("run_repository") }
        if (policyValue.isNone()) { values.add("policy") }
        if (budgetValue.isNone()) { values.add("budget") }
        if (promptValue.isNone()) { values.add("prompt") }
        if (operationsValue.isNone()) { values.add("operation_repository") }
        if (auditValue.isNone()) { values.add("audit") }
        if (idsValue.isNone()) { values.add("ids") }
        values.toArray()
    }
}

@Derive[Equatable]
public enum SdkRunStatus {
    Completed | AwaitingApproval
}

public class SdkPendingApproval {
    public let request: AgentRunRequest
    public let approval: ApprovalRequest

    init(request: AgentRunRequest, approval: ApprovalRequest) {
        this.request = request
        this.approval = approval
    }
}

public class SdkRunResult {
    public let status: SdkRunStatus
    public let snapshot: RunSnapshot
    public let pending: ?SdkPendingApproval
    public let structuredOutput: ?AgentValue

    init(status: SdkRunStatus, snapshot: RunSnapshot, pending: ?SdkPendingApproval) {
        this.status = status
        this.snapshot = snapshot
        this.pending = pending
        this.structuredOutput = snapshot.structuredOutput
    }
}

public class AgentSdk {
    private let runner: AgentRunner
    private let ids: IdGenerator
    private let session: SessionBinding
    private let threadRuntimes: ThreadRuntimeRegistry
    private let pricing: ?ModelPricing
    public let configuration: AgentSdkConfiguration

    init(
        runner: AgentRunner,
        ids: IdGenerator,
        session: SessionBinding,
        threadRuntimes: ThreadRuntimeRegistry,
        configuration: AgentSdkConfiguration,
        pricing!: ?ModelPricing = None
    ) {
        this.runner = runner
        this.ids = ids
        this.session = session
        this.threadRuntimes = threadRuntimes
        this.configuration = configuration
        this.pricing = pricing
    }

    public func sessionId(): SessionId {
        session.id
    }

    public func transcript(): Result<Array<ModelMessage>> {
        match (threadRuntimes.acquire(
            ThreadId(session.id.value), "agent-sdk"
        )) {
            case Result.Ok(runtime) => Result.Ok(
                modelMessagesFromCanonicalItems(runtime.threadSnapshot().items)
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func run(
        prompt: String,
        eventSink!: AgentEventSink = { _ => () },
        cancellation!: ?CancellationToken = None
    ): Result<SdkRunResult> {
        runWithImages(
            prompt,
            [],
            eventSink: eventSink,
            cancellation: cancellation
        )
    }

    public func runWithImages(
        prompt: String,
        images: Array<ModelImage>,
        eventSink!: AgentEventSink = { _ => () },
        cancellation!: ?CancellationToken = None
    ): Result<SdkRunResult> {
        if (prompt.trimAscii() == "") {
            return sdkError<SdkRunResult>(
                AgentErrorKind.InvalidInput,
                "sdk.prompt_required",
                "run prompt must not be empty"
            )
        }
        let runId = try {
            ids.nextRunId()
        } catch (error: Exception) {
            return sdkError<SdkRunResult>(
                AgentErrorKind.Internal,
                "sdk.run_id_failed",
                "failed to allocate run id: " + error.message
            )
        }
        let request = AgentRunRequest(
            runId,
            session.id,
            configuration.model.value,
            prompt,
            system: configuration.prompt.value.text,
            thinking: configuration.thinking.value,
            capabilities: configuration.capabilities.value,
            budget: configuration.budget.value,
            autoRetry: configuration.autoRetry.value,
            serviceTier: configuration.serviceTier.value,
            pricing: pricing,
            imageInputs: images,
            structuredOutput: configuration.structuredOutput.value,
            cachePolicy: configuration.cachePolicy.value,
            cacheKey: match (configuration.cachePolicy.value) {
                case ModelCachePolicy.StablePrefix =>
                    configuration.prompt.value.stablePrefixHash
                case ModelCachePolicy.Default => ""
            },
            parallelToolCalls: configuration.parallelToolCalls.value,
            toolContext: configuration.toolContext.value,
            skillStack: configuration.skillStack.value
        )
        execute(
            request.runId,
            cancellation,
            eventSink,
            { sink => runner.start(request, sink) },
            { outcome => sdkOutcome(request, outcome) }
        )
    }

    public func run(
        prompt: String,
        eventSink: AgentEventSink,
        cancellation: CancellationToken
    ): Result<SdkRunResult> {
        run(prompt, eventSink: eventSink, cancellation: Some(cancellation))
    }

    public func runWithImages(
        prompt: String,
        images: Array<ModelImage>,
        eventSink: AgentEventSink,
        cancellation: CancellationToken
    ): Result<SdkRunResult> {
        runWithImages(
            prompt,
            images,
            eventSink: eventSink,
            cancellation: Some(cancellation)
        )
    }

    public func continueApproval(
        pending: SdkPendingApproval,
        decision: ApprovalDecision,
        eventSink!: AgentEventSink = { _ => () },
        cancellation!: ?CancellationToken = None
    ): Result<SdkRunResult> {
        if (pending.request.sessionId.value != session.id.value) {
            return sdkError<SdkRunResult>(
                AgentErrorKind.Conflict,
                "sdk.approval_session_mismatch",
                "pending approval belongs to another SDK session"
            )
        }
        execute(
            pending.request.runId,
            cancellation,
            eventSink,
            { sink => runner.decide(pending.request, pending.approval, decision, sink) },
            { outcome => sdkOutcome(pending.request, outcome) }
        )
    }

    public func continueApproval(
        pending: SdkPendingApproval,
        decision: ApprovalDecision,
        eventSink: AgentEventSink,
        cancellation: CancellationToken
    ): Result<SdkRunResult> {
        continueApproval(
            pending,
            decision,
            eventSink: eventSink,
            cancellation: Some(cancellation)
        )
    }

    public func cancel(runId: RunId): Result<Unit> {
        runner.cancel(runId)
    }

    private func execute(
        runId: RunId,
        parentCancellation: ?CancellationToken,
        eventSink: AgentEventSink,
        action: (AgentEventSink) -> Result<AgentRunOutcome>,
        convert: (AgentRunOutcome) -> SdkRunResult
    ): Result<SdkRunResult> {
        let source = CancellationSource(
            parent: parentCancellation,
            deadlineMillis: configuration.budget.value.deadlineMillis
        )
        match (resolvedSdkCancellationReason(source.token, parentCancellation)) {
            case Some(reason) =>
                source.close()
                return Result.Err(sdkCancellationError(reason))
            case None => ()
        }
        let bridge = SdkCancellationBridge(runner, runId)
        let registration = source.token.onCancel({ reason => bridge.cancel(reason) })
        let monitorState = SdkCancellationMonitorState()
        let monitor = spawn {
            while (!monitorState.isFinished()) {
                if (source.token.isCancelled()) {
                    bridge.cancel(match (source.token.reason()) {
                        case Some(value) => value
                        case None => CancellationReason(
                            CancellationReasonKind.User,
                            "run.cancelled",
                            "execution was cancelled"
                        )
                    })
                    // A failed cancellation dispatch is retried by this
                    // bounded monitor. A blocked external cancel call remains
                    // isolated in the bridge worker instead of blocking the
                    // SDK invocation or this monitor.
                    bridge.retryAfterEvent()
                }
                sleep(Duration.millisecond * 10)
            }
        }
        let bridgedSink: AgentEventSink = { event =>
            try {
                eventSink(event)
            } finally {
                bridge.retryAfterEvent()
            }
        }
        try {
            let outcome = action(bridgedSink)
            bridge.deactivate()
            match (outcome) {
                case Result.Ok(value) => Result.Ok(convert(value))
                case Result.Err(error) => match (resolvedSdkCancellationReason(
                    source.token,
                    parentCancellation
                )) {
                    case Some(reason) => Result.Err(sdkCancellationError(reason))
                    case None => Result.Err(error)
                }
            }
        } catch (error: Exception) {
            bridge.deactivate()
            match (resolvedSdkCancellationReason(source.token, parentCancellation)) {
                case Some(reason) => Result.Err(sdkCancellationError(reason))
                case None => sdkError<SdkRunResult>(
                    AgentErrorKind.Internal,
                    "sdk.run_failed",
                    "embedded run failed: " + error.message
                )
            }
        } finally {
            monitorState.finish()
            registration.dispose()
            source.close()
            waitForSdkCancellationMonitor(monitor)
        }
    }
}

class CapabilityValidatedModelPort <: ModelPort {
    private let inner: ModelPort
    private let capabilities: ModelCapabilities

    init(inner: ModelPort, capabilities: ModelCapabilities) {
        this.inner = inner
        this.capabilities = capabilities
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        match (capabilities.validate(request)) {
            case Result.Ok(_) => inner.execute(request, events)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(requestId: String): Result<Unit> {
        inner.cancel(requestId)
    }
}

class SdkCancellationBridge {
    private let lock = Mutex()
    private let runner: AgentRunner
    private let runId: RunId
    private var active: Bool = true
    private var cancelled: Bool = false
    private var applied: Bool = false
    private var inFlight: Bool = false
    private var attempts: Int64 = 0
    private let maxAttempts: Int64 = 8

    init(runner: AgentRunner, runId: RunId) {
        this.runner = runner
        this.runId = runId
    }

    func cancel(reason: CancellationReason): Unit {
        let _ = reason
        lock.lock()
        try {
            cancelled = true
        } finally {
            lock.unlock()
        }
        scheduleAttempt()
    }

    func retryAfterEvent(): Unit {
        scheduleAttempt()
    }

    func deactivate(): Unit {
        lock.lock()
        try {
            active = false
        } finally {
            lock.unlock()
        }
    }

    private func scheduleAttempt(): Unit {
        var shouldStart = false
        lock.lock()
        try {
            if (active && cancelled && !applied && !inFlight &&
                attempts < maxAttempts) {
                inFlight = true
                attempts += 1
                shouldStart = true
            }
        } finally {
            lock.unlock()
        }
        if (shouldStart) {
            let _ = spawn { applyAttempt() }
        }
    }

    private func applyAttempt(): Unit {
        // Re-check after the worker is scheduled. No external code is ever
        // invoked while the bridge mutex is held.
        var shouldApply = false
        lock.lock()
        try {
            shouldApply = active && cancelled && !applied
        } finally {
            lock.unlock()
        }
        if (!shouldApply) {
            lock.lock()
            try { inFlight = false } finally { lock.unlock() }
            return
        }
        let succeeded = try {
            runner.cancel(runId).isOk()
        } catch (_: Exception) {
            false
        }
        lock.lock()
        try {
            inFlight = false
            if (succeeded) { applied = true }
        } finally {
            lock.unlock()
        }
    }
}

class SdkCancellationMonitorState {
    private let lock = Mutex()
    private var finished: Bool = false

    func finish(): Unit {
        lock.lock()
        try { finished = true } finally { lock.unlock() }
    }

    func isFinished(): Bool {
        lock.lock()
        try { finished } finally { lock.unlock() }
    }
}

func waitForSdkCancellationMonitor(monitor: Future<Unit>): Unit {
    var waited: Int64 = 0
    while (monitor.tryGet().isNone() && waited < 100) {
        sleep(Duration.millisecond)
        waited += 1
    }
    if (monitor.tryGet().isSome()) {
        monitor.get()
    }
}

func resolvedSdkCancellationReason(
    token: CancellationToken,
    parent: ?CancellationToken
): ?CancellationReason {
    match (token.reason()) {
        case Some(reason) =>
            if (reason.kind == CancellationReasonKind.Parent) {
                match (parent) {
                    case Some(value) => match (value.reason()) {
                        case Some(parentReason) => Some(parentReason)
                        case None => Some(reason)
                    }
                    case None => Some(reason)
                }
            } else {
                Some(reason)
            }
        case None => None
    }
}

func sdkCancellationError(reason: CancellationReason): AgentError {
    let kind = match (reason.kind) {
        case CancellationReasonKind.Deadline => AgentErrorKind.Timeout
        case CancellationReasonKind.Budget => AgentErrorKind.BudgetExceeded
        case _ => AgentErrorKind.Cancelled
    }
    AgentError(
        kind,
        reason.code,
        reason.message,
        fields: [
            ErrorField("reason_kind", sdkCancellationReasonKindName(reason.kind)),
            ErrorField("cancelled_at_millis", reason.cancelledAtMillis.toString())
        ]
    )
}

func sdkCancellationReasonKindName(kind: CancellationReasonKind): String {
    match (kind) {
        case CancellationReasonKind.User => "user"
        case CancellationReasonKind.Deadline => "deadline"
        case CancellationReasonKind.Budget => "budget"
        case CancellationReasonKind.Parent => "parent"
        case CancellationReasonKind.Shutdown => "shutdown"
        case CancellationReasonKind.Failure => "failure"
    }
}

func sdkOutcome(request: AgentRunRequest, outcome: AgentRunOutcome): SdkRunResult {
    match (outcome) {
        case AgentRunOutcome.Completed(snapshot) => SdkRunResult(
            SdkRunStatus.Completed,
            snapshot,
            None
        )
        case AgentRunOutcome.AwaitingApproval(snapshot, approval) => SdkRunResult(
            SdkRunStatus.AwaitingApproval,
            snapshot,
            Some(SdkPendingApproval(request, approval))
        )
    }
}

func validateModelConfiguration(
    model: ModelBinding,
    catalog: ToolCatalog,
    grantedCapabilities: CapabilitySet,
    thinking: ThinkingLevel,
    budget: ResourceBudget,
    system: String,
    structuredOutput: ?StructuredOutputSpec,
    cachePolicy: ModelCachePolicy,
    cacheKey: String,
    parallelToolCalls: Bool
): Result<Unit> {
    if (budget.maxOutputTokens > model.capabilities.maxOutputTokens) {
        return sdkError<Unit>(
            AgentErrorKind.Configuration,
            "sdk.model_output_limit",
            "configured output budget exceeds model capability",
            fields: [
                ErrorField("budget", budget.maxOutputTokens.toString()),
                ErrorField("model_limit", model.capabilities.maxOutputTokens.toString())
            ]
        )
    }
    if (budget.maxInputTokens > model.capabilities.contextWindowTokens - budget.maxOutputTokens) {
        return sdkError<Unit>(
            AgentErrorKind.Configuration,
            "sdk.model_context_limit",
            "configured input and output budgets exceed the model context window",
            fields: [
                ErrorField("input_budget", budget.maxInputTokens.toString()),
                ErrorField("output_budget", budget.maxOutputTokens.toString()),
                ErrorField("context_window", model.capabilities.contextWindowTokens.toString())
            ]
        )
    }
    model.capabilities.validate(ModelRequest(
        model.name,
        [],
        system: system,
        tools: catalog.definitionsFor(grantedCapabilities),
        thinking: thinking,
        maxOutputTokens: budget.maxOutputTokens,
        parallelToolCalls: parallelToolCalls,
        structuredOutput: structuredOutput,
        cachePolicy: cachePolicy,
        cacheKey: match (cachePolicy) {
            case ModelCachePolicy.StablePrefix => cacheKey
            case ModelCachePolicy.Default => ""
        }
    ))
}

func selectOrigin<T>(current: ?OriginValue<T>, candidate: OriginValue<T>): OriginValue<T> {
    match (current) {
        case Some(value) => value.merged(candidate)
        case None => candidate
    }
}

func stringOrigin<T>(source: OriginValue<T>, value: String): OriginValue<String> {
    OriginValue<String>(source.key, value, source.origin, secret: source.secret)
}

func joinStrings(values: Array<String>, separator: String): String {
    var result = ""
    for (index in 0..values.size) {
        if (index > 0) { result += separator }
        result += values[index]
    }
    result
}

func sdkError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(AgentError(kind, code, message, fields: fields))
}
