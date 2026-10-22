package agent_core

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_domain.CancellationRegistration as InternalCallCancellationRegistration
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.overflow.*
import std.time.*
import std.sync.*
import tool_runtime.*

// A constant reference supports the actual Cangjie indirect callback rule.
// Explicitly fund its conservative metadata before allocating it, using the
// original consumer's cumulative same-bank invoice. It is not a new Source,
// budget or floor exemption. Charge remains until that consumer's real ACK.
class CoreCheckpointMetadataResult143 {
    var value = Result<Unit>.Ok(())
}
func coreCheckpointMetadataCellPayment143(consumer: OwnedFailureDataConsumer113): Result<Unit> {
    try {
        consumer.withError({ _, fund =>
            match (fund(4096)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => ()
            }
        })
    } catch (failure: OwnedCanonicalDataFailure113) { Result<Unit>.Err(failure.error) }
}

class CoreCheckpointFailureKind143 {
    var value = AgentErrorKind.RecoveryRequired
}

class CoreToolOutputSink <: ToolOutputSink {
    private let lock = Mutex()
    private var emitter: ?(ToolOutputChunk) -> Result<Unit> = None

    init() {}

    func bind(handler: (ToolOutputChunk) -> Result<Unit>): Unit {
        lock.lock()
        try {
            if (emitter.isSome()) {
                throw IllegalStateException("Core ToolOutput sink is already bound")
            }
            emitter = Some(handler)
        } finally {
            lock.unlock()
        }
    }

    public func emit(chunk: ToolOutputChunk): Result<Unit> {
        // Serialize sequence allocation and durable append for parallel tool waves.
        lock.lock()
        try {
            match (emitter) {
                case Some(handler) => handler(chunk)
                case None => Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "tool.output_sink_unbound",
                    "Core ToolOutput sink was used before event binding"
                ))
            }
        } finally {
            lock.unlock()
        }
    }
}

private let MODEL_RETRY_MAX_DELAY_MILLIS: Int64 = 8000
private let MODEL_RETRY_POLL_MILLIS: Int64 = 10

@Derive[Equatable]
public enum QueueDeliveryMode {
    All | OneAtATime
}

@Derive[Equatable]
public enum RunInterruptMode {
    Immediate | Wait
}

public class AgentQueuedInput {
    public let text: String
    public let correlationId: String
    public let kind: String
    public let durableItemId: String

    public init(
        text: String,
        correlationId!: String = "",
        kind!: String = "steer",
        durableItemId!: String = ""
    ) {
        if (text.trimAscii() == "") {
            throw IllegalArgumentException("queued agent input must not be empty")
        }
        this.text = text
        this.correlationId = correlationId
        this.kind = kind
        this.durableItemId = durableItemId
    }
}

public interface AgentInteractionSource {
    func takeSteering(): Array<AgentQueuedInput>
    func hasSteering(): Bool
    func takeFollowUps(): Array<AgentQueuedInput>
    func interruptMode(): RunInterruptMode
}

public class AgentRunRequest {
    public let runId: RunId
    public let sessionId: SessionId
    public let model: String
    public let prompt: String
    public let system: String
    public let thinking: ThinkingLevel
    public let requestedPolicy: RequestedModelPolicy
    public let modelCapabilitiesSnapshot: ModelExecutionCapabilitiesSnapshot
    public let resolverVersion: UInt32
    public let capabilities: CapabilitySet
    public let budget: ResourceBudget
    public let interactions: ?AgentInteractionSource
    public let approvalModeOverride: ?ApprovalMode
    public let callerCancellation180: ?CancellationToken
    public let autoRetry: Bool
    public let serviceTier: String
    public let pricing: ?ModelPricing
    public let imageInputs: Array<ModelImage>
    public let structuredOutput: ?StructuredOutputSpec
    public let cachePolicy: ModelCachePolicy
    public let cacheKey: String
    public let parallelToolCalls: Bool
    public let toolContext: ToolContextDescriptor
    public let contextSnapshot: InvocationContextProjection
    public let initializeContext: Bool
    public let ownedEvents: ?OwnedAgentEventSink
    public let contextWindow: Int64
    public let providerSafetyMargin: Int64
    // Semantic execution enclosure. ModelLane remains the immutable model/tool
    // capability snapshot and must not be used as a Thread branch identity.
    public let executionLaneId: LaneId
    public let queuedInitiator113: ?QueuedRunInitiatorData113
    public let queuedInputPayment113: ?LogicalJsonOwnerReservation

    public init(
        runId: RunId,
        sessionId: SessionId,
        model: String,
        prompt: String,
        system!: String = "",
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        userRequestedThinking!: ?ThinkingLevel = None,
        thinkingSource!: ThinkingPreferenceSource = ThinkingPreferenceSource.ModelDefault,
        modelCapabilitiesSnapshot!: ?ModelExecutionCapabilitiesSnapshot = None,
        resolverVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION,
        capabilities!: CapabilitySet = CapabilitySet(),
        budget!: ResourceBudget = ResourceBudget(),
        interactions!: ?AgentInteractionSource = None,
        approvalModeOverride!: ?ApprovalMode = None,
        callerCancellation180!: ?CancellationToken = None<CancellationToken>,
        autoRetry!: Bool = true,
        serviceTier!: String = "",
        pricing!: ?ModelPricing = None,
        imageInputs!: Array<ModelImage> = [],
        structuredOutput!: ?StructuredOutputSpec = None,
        cachePolicy!: ModelCachePolicy = ModelCachePolicy.Default,
        cacheKey!: String = "",
        parallelToolCalls!: Bool = false,
        toolContext!: ToolContextDescriptor = ToolContextDescriptor(),
        contextSnapshot!: InvocationContextProjection = InvocationContextProjection(),
        contextWindow!: Int64 = 0,
        providerSafetyMargin!: Int64 = 1024,
        executionLaneId!: LaneId = LaneId("main"),
        initializeContext!: Bool = false,
        ownedEvents!: ?OwnedAgentEventSink = None,
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ) {
        if (prompt.trimAscii() == "") {
            throw IllegalArgumentException("agent prompt must not be empty")
        }
        if (contextWindow < 0 || providerSafetyMargin < 0) {
            throw IllegalArgumentException("model context limits must not be negative")
        }
        this.runId = runId
        this.sessionId = sessionId
        this.model = model
        this.prompt = prompt
        this.system = system
        this.thinking = thinking
        this.requestedPolicy = RequestedModelPolicy(
            thinking,
            budget.requestOutputBudget,
            userRequestedThinking: userRequestedThinking,
            thinkingSource: thinkingSource
        )
        this.modelCapabilitiesSnapshot = match (modelCapabilitiesSnapshot) {
            case Some(value) => value
            case None => ModelExecutionCapabilitiesSnapshot(
                model,
                if (thinking == ThinkingLevel.Off) {
                    ThinkingCapabilities(ThinkingControlMode.NoThinking)
                } else {
                    ThinkingCapabilities(
                        ThinkingControlMode.Effort,
                        supportedLevels: canonicalNonOffThinkingLevels()
                    )
                },
                budget.maxOutputTokens
            )
        }
        this.resolverVersion = resolverVersion
        this.capabilities = capabilities
        this.budget = budget
        this.interactions = interactions
        this.approvalModeOverride = approvalModeOverride
        this.callerCancellation180 = callerCancellation180
        this.autoRetry = autoRetry
        this.serviceTier = serviceTier
        this.pricing = pricing
        this.imageInputs = imageInputs
        this.structuredOutput = structuredOutput
        this.cachePolicy = cachePolicy
        this.cacheKey = cacheKey.trimAscii()
        this.parallelToolCalls = parallelToolCalls
        this.contextSnapshot = contextSnapshot
        this.initializeContext = initializeContext
        this.ownedEvents = match (ownedEvents) {
            case Some(value) => Some(value)
            case None => match (interactions) {
                case Some(value) => match (value as OwnedAgentEventSource) {
                    case Some(source) => Some(source.ownedEventSink())
                    case None => None }
                case None => None }
        }
        this.providerSafetyMargin = providerSafetyMargin
        this.executionLaneId = executionLaneId
        match (queuedInitiator113) {
            case Some(value) => if (value.threadId.value != sessionId.value ||
                value.laneId.value != executionLaneId.value || value.input != prompt || !imageInputs.isEmpty()) {
                throw IllegalArgumentException("queued initiator differs from the actual Run request") }
            case None => () }
        if (queuedInitiator113.isSome() != queuedInputPayment113.isSome()) {
            throw IllegalArgumentException("queued input requires its actual retained DATA payment") }
        this.queuedInitiator113 = queuedInitiator113
        this.queuedInputPayment113 = queuedInputPayment113
        this.contextWindow = if (contextWindow > 0) {
            contextWindow
        } else if (budget.maxInputTokens > Int64.Max - budget.maxOutputTokens -
            providerSafetyMargin) {
            Int64.Max
        } else {
            budget.maxInputTokens + budget.maxOutputTokens + providerSafetyMargin
        }
        this.toolContext = ToolContextDescriptor(toolContext)
    }
}

func requestWithContextSnapshot(request: AgentRunRequest, snapshot: InvocationContextProjection): AgentRunRequest {
    AgentRunRequest(request.runId, request.sessionId, request.model, request.prompt,
        system: request.system, thinking: request.thinking,
        userRequestedThinking: request.requestedPolicy.userRequestedThinking,
        thinkingSource: request.requestedPolicy.thinkingSource,
        modelCapabilitiesSnapshot: Some(request.modelCapabilitiesSnapshot), resolverVersion: request.resolverVersion,
        capabilities: request.capabilities, budget: request.budget, interactions: request.interactions,
        approvalModeOverride: request.approvalModeOverride, autoRetry: request.autoRetry,
        callerCancellation180: request.callerCancellation180,
        serviceTier: request.serviceTier, pricing: request.pricing, imageInputs: request.imageInputs,
        structuredOutput: request.structuredOutput, cachePolicy: request.cachePolicy, cacheKey: request.cacheKey,
        parallelToolCalls: request.parallelToolCalls, toolContext: request.toolContext,
        contextSnapshot: snapshot, contextWindow: request.contextWindow,
        providerSafetyMargin: request.providerSafetyMargin, executionLaneId: request.executionLaneId,
        ownedEvents: request.ownedEvents, queuedInitiator113: request.queuedInitiator113, queuedInputPayment113: request.queuedInputPayment113)
}

public enum AgentRunOutcome {
    Completed(RunSnapshot)
    | AwaitingApproval(RunSnapshot, ApprovalRequest)
}

public interface AgentRunner {
    // Existing runners keep their original single call. The actual Core
    // overrides these methods with its paid failure consumer handoff.
    func startOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(start(request, sink))
    }
    func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resumeContextBoundary(request, sink))
    }
    func resumeOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resume(request, sink))
    }
    func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest,
        decision: ApprovalDecision, sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(decide(request, approval, decision, sink))
    }
    func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 {
        let _ = run
        OwnedAgentRunResult113.Held
    }

    // Unsupported transports must not infer a finite wave from Held.
    func prepareOwnedCheckpointWave113(run: RunId,
        events!: ?OwnedAgentEventSink): (Bool, Int64, Int64) { (false, 0, 0) }

    func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool { None<Bool> }

    func retireOwnedCheckpointProducerWitness113(run: RunId): Unit { () }

    func startRestricted111(request: AgentRunRequest, restriction: AgentRunStartRestriction111,
        events: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "child.start_restriction_unsupported",
            "this transport cannot carry the original live start restriction"))
    }

    func startContinuation(value: AgentContinuationStart, sink: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "continuation.runner_unsupported", "runner cannot start a sealed continuation"))
    }

    func start(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome>

    func cancel(runId: RunId): Result<Unit>

    func resumeContextBoundary(request: AgentRunRequest, sink: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(coreContextBoundaryError("runner cannot recover a context boundary"))
    }

    func resume(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let _ = request
        let _ = sink
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.model_resume_unavailable",
            "agent runner does not support durable model execution recovery"
        ))
    }

    func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome>
}

class BudgetCounter {
    var modelRequests: Int64
    var workModelRequests: Int64
    var drainModelRequests: Int64
    var inputTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var cacheReadTokens: Int64
    var cacheWriteTokens: Int64
    var costMicros: ?Int64
    var lastInputTokens: Int64
    var lastOutputTokens: Int64
    var lastRequestDurationMillis: Int64
    var toolCalls: Int64
    var turns: Int64
    let startedAt: MonoTime
    let wallStartedAtMillis: Int64

    init(
        modelRequests!: Int64 = 0,
        workModelRequests!: Int64 = 0,
        drainModelRequests!: Int64 = 0,
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        lastInputTokens!: Int64 = 0,
        lastOutputTokens!: Int64 = 0,
        lastRequestDurationMillis!: Int64 = 0,
        toolCalls!: Int64 = 0,
        turns!: Int64 = 0,
        restoredWallStart!: ?Int64 = None
    ) {
        this.modelRequests = modelRequests
        this.workModelRequests = workModelRequests
        this.drainModelRequests = drainModelRequests
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
        this.costMicros = costMicros
        this.lastInputTokens = lastInputTokens
        this.lastOutputTokens = lastOutputTokens
        this.lastRequestDurationMillis = lastRequestDurationMillis
        this.toolCalls = toolCalls
        this.turns = turns
        match (restoredWallStart) {
            case None => this.wallStartedAtMillis = agentUtcMillis(); this.startedAt = MonoTime.now()
            case Some(start) =>
                let now = agentUtcMillis()
                if (start < 0 || now < start) { throw IllegalArgumentException("context boundary wall clock moved before its original start") }
                this.wallStartedAtMillis = start
                this.startedAt = MonoTime.now() - Duration.millisecond * (now - start)
        }
    }

    func recordModelRequest(mode: BudgetMode): Unit {
        modelRequests += 1
        if (mode == BudgetMode.Draining) {
            drainModelRequests += 1
        } else {
            workModelRequests += 1
        }
    }

    func accountObservedUsage(usage: ModelUsage): Unit {
        inputTokens = saturatedModelUsageAdd(inputTokens, usage.inputTokens)
        outputTokens = saturatedModelUsageAdd(outputTokens, usage.outputTokens)
        reasoningTokens = saturatedModelUsageAdd(reasoningTokens, usage.reasoningTokens)
        cacheReadTokens = saturatedModelUsageAdd(cacheReadTokens, usage.cacheReadTokens)
        cacheWriteTokens = saturatedModelUsageAdd(cacheWriteTokens, usage.cacheWriteTokens)
        costMicros = match ((costMicros, usage.costMicros)) {
            case (Some(total), Some(value)) => Some(saturatedModelUsageAdd(total, value))
            case (cost, None) => cost
            case (None, Some(value)) => Some(value)
        }
        lastInputTokens = usage.inputTokens
        lastOutputTokens = usage.outputTokens
    }

    // Every provider attempt, including one that fails after consuming
    // tokens, uses the same per-request ceilings. The observed facts remain
    // in the counter even when the attempt is rejected.
    func accountAttemptUsage(
        usage: ModelUsage,
        budget: ResourceBudget
    ): Result<Unit> {
        accountObservedUsage(usage)
        if (usage.inputTokens > budget.maxInputTokens) {
            return budgetError("input_tokens")
        }
        if (usage.outputTokens > budget.maxOutputTokens) {
            return budgetError("output_tokens")
        }
        Result.Ok(())
    }


    // Token budgets are per-request ceilings: maxInputTokens / maxOutputTokens
    // bound a single model request (the API's reported usage for that turn).
    // The counters keep accumulating for usage reporting, but a long multi-turn
    // session must never be killed just because history accumulated — that is
    // what context compaction (maxContextMessages) is for.
    func accountReply(
        reply: ModelReply,
        budget: ResourceBudget,
        pricing: ?ModelPricing,
        durationMillis: Int64
    ): Result<Unit> {
        let requestCost: ?Int64 = match (pricing) {
            case Some(value) => priceModelUsage(reply.usage, value)
            case None => reply.usage.costMicros
        }
        accountObservedUsage(ModelUsage(
            inputTokens: reply.inputTokens,
            outputTokens: reply.outputTokens,
            reasoningTokens: reply.reasoningTokens,
            cacheReadTokens: reply.cacheReadTokens,
            cacheWriteTokens: reply.cacheWriteTokens,
            costMicros: requestCost
        ))
        lastRequestDurationMillis = max(0, durationMillis)
        if (reply.inputTokens > budget.maxInputTokens) {
            return budgetError("input_tokens")
        }
        if (reply.outputTokens > budget.maxOutputTokens) {
            return budgetError("output_tokens")
        }
        Result.Ok(())
    }

    func usage(): ModelUsage {
        ModelUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            costMicros: costMicros
        )
    }


    private func budgetError(resource: String): Result<Unit> {
        Result.Err(
            AgentError(
                AgentErrorKind.BudgetExceeded,
                "run.budget_exceeded",
                "agent resource budget exceeded",
                fields: [ErrorField("resource", resource)]
            )
        )
    }
}

func saturatedModelUsageAdd(left: Int64, right: Int64): Int64 {
    if (right > Int64.Max - left) { Int64.Max } else { left + right }
}

class CoreExecutionHandoffState {
    var started: Bool = false
}

class DurableModelResult {
    let reply: ModelReply
    let decision: ModelDecision
    let recovered: Bool
    init(reply: ModelReply, decision: ModelDecision, recovered!: Bool = false) {
        this.reply = reply
        this.decision = decision
        this.recovered = recovered
    }
}

class PreparedModelRequest {
    let requestId: RequestId
    private var requestValue159: ?ModelRequest
    prop request: ModelRequest { get() { requestValue159.getOrThrow() } }
    let estimatedInputTokens: Int64
    // Strong typed carrier; source snapshot does not escape with these copies.
    // Caller/store retirement is a separate actual-frame migration below.
    private var ownedTools159: ?OwnedModelTools159

    init(requestId: RequestId, request: ModelRequest, estimatedInputTokens: Int64,
        ownedTools159!: ?OwnedModelTools159 = None) {
        this.requestId = requestId
        this.requestValue159 = Some(request)
        this.estimatedInputTokens = estimatedInputTokens
        this.ownedTools159 = ownedTools159
    }
    func borrowTools159(): ?ModelInputToolsBorrow159 {
        match (ownedTools159) { case Some(value) => Some(value.borrowModelTools159()); case None => None<ModelInputToolsBorrow159> }
    }
    func returnPreparedFrame159(): Unit {
        let owner = clearPreparedFrame159()
        match (owner) { case Some(value) => value.closeAfterPreparedFrame159(); case None => () }
    }
    private func clearPreparedFrame159(): ?OwnedModelTools159 {
        requestValue159 = None<ModelRequest>
        let owner = ownedTools159; ownedTools159 = None<OwnedModelTools159>
        owner
    }
}

// Text and reasoning deltas are provisional until the attempt's terminal
// outcome is known. They are delivered to the attempt-scoped live sink as
// soon as observed; canonical transcript projection still waits for the
// validated durable ModelDecision.
class ModelAttemptExecution {
    let result: Result<ModelReply>
    let provisionalEvents: Array<ModelEvent>
    var replayBarrier = ModelAttemptReplayBarrier.NoBarrier

    init(result: Result<ModelReply>, provisionalEvents: Array<ModelEvent>) {
        this.result = result
        this.provisionalEvents = provisionalEvents
    }
}

class ModelAttemptDispatch {
    let execution: ModelAttemptExecution
    let startedAt: MonoTime

    init(execution: ModelAttemptExecution, startedAt: MonoTime) {
        this.execution = execution
        this.startedAt = startedAt
    }
}

// The provider request is not allowed to cross the effect boundary until its
// exact, provider-neutral inputs have been durably described. Production
// supplies a SQLite-backed implementation; the in-memory default preserves
// embedders that do not opt into durable execution.
public interface ModelContextManifestRuntimePort {
    func recordBeforeModelEffect(
        request: AgentRunRequest,
        requestId: RequestId,
        turnId: SemanticTurnId,
        executionLaneId: LaneId,
        stepId: StepId,
        stepOrdinal: Int64,
        projection: ModelContextProjection,
        lane: ModelLane,
        renderedRequest: AgentValue,
        estimatedInputTokens: Int64,
        observedAtMillis: Int64
    ): Result<Unit>
}

class InMemoryModelContextManifestRuntimePort <: ModelContextManifestRuntimePort {
    public init() {}
    public func recordBeforeModelEffect(
        request: AgentRunRequest,
        requestId: RequestId,
        turnId: SemanticTurnId,
        executionLaneId: LaneId,
        stepId: StepId,
        stepOrdinal: Int64,
        projection: ModelContextProjection,
        lane: ModelLane,
        renderedRequest: AgentValue,
        estimatedInputTokens: Int64,
        observedAtMillis: Int64
    ): Result<Unit> {
        let _ = request
        let _ = requestId
        let _ = turnId
        let _ = executionLaneId
        let _ = stepId
        let _ = stepOrdinal
        let _ = projection
        let _ = lane
        let _ = renderedRequest
        let _ = estimatedInputTokens
        let _ = observedAtMillis
        Result.Ok(())
    }
}

enum CoreTurnExecution {
    ReadyToFinish(ModelReply, Bool)
    | Finished(AgentRunOutcome)
}

public enum CoreToolHookDecision {
    Continue | Deny(String) | Modify(AgentValue)
}

public class CoreToolHookPostEvent {
    public let toolName: String
    public let arguments: AgentValue
    public let operationId: String
    public let receiptId: String
    public let outcome: String
    public let requiredCapabilities: Array<Capability>
    public let result: ?AgentValue

    public init(
        toolName: String,
        arguments: AgentValue,
        operationId: String,
        receiptId: String,
        outcome: String,
        requiredCapabilities: Array<Capability>,
        result!: ?AgentValue = None
    ) {
        this.toolName = toolName
        this.arguments = arguments
        this.operationId = operationId
        this.receiptId = receiptId
        this.outcome = outcome
        this.requiredCapabilities = requiredCapabilities
        this.result = result
    }
}

public interface CoreToolHookRuntime {
    func beforeTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        arguments: AgentValue
    ): CoreToolHookDecision

    func afterTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        event: CoreToolHookPostEvent
    ): Unit
}

class NoopCoreToolHookRuntime <: CoreToolHookRuntime & OwnedCoreToolHookRuntime {
    public func afterOwnedTool(context: ToolInvocationContext, committed: CommittedToolCallRef,
        eventFactory: (ThreadItem) -> CoreToolHookPostEvent,
        held: OwnedCanonicalThreadItemAliasCustody): Result<Unit> {
        let _ = context; let _ = committed; let _ = eventFactory; let _ = held
        Result.Ok(())
    }

    public func beforeTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        arguments: AgentValue
    ): CoreToolHookDecision {
        let _ = context
        let _ = committed
        let _ = arguments
        CoreToolHookDecision.Continue
    }

    public func afterTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        event: CoreToolHookPostEvent
    ): Unit {
        let _ = context
        let _ = committed
        let _ = event
    }
}

public class AgentCore <: AgentRunner {
    private let model: ControlledModelPort
    private let runs: RunRepository
    private let tools: ToolPipeline
    private let catalog: ToolCatalog
    private let threadRuntimes: ThreadRuntimeRegistry
    private let operationRuntime: OperationRuntimePort
    private let modelDecisionRuntime: ModelDecisionRuntimePort
    private let contextManifestRuntime: ModelContextManifestRuntimePort
    private let modelAttemptRecovery: ModelAttemptRecoveryPolicy
    private let attemptClock: AttemptMonotonicClock
    private let toolHooks: CoreToolHookRuntime
    private let initialContext: ?InitialContextPreparationPort
    private let controls = CoreRunControlRegistry()
    public func collectReturnedModelInputs159(): Unit { controls.collectReturnedModelInputs159() }


    public init(
        model: ModelPort,
        runs: RunRepository,
        tools: ToolPipeline,
        catalog: ToolCatalog,
        threadRuntimes!: ?ThreadRuntimeRegistry = None,
        operationRuntime!: ?OperationRuntimePort = None,
        modelDecisionRuntime!: ?ModelDecisionRuntimePort = None,
        contextManifestRuntime!: ?ModelContextManifestRuntimePort = None,
        modelAttemptRecovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy(),
        attemptClock!: AttemptMonotonicClock = SystemAttemptMonotonicClock(),
        toolHooks!: CoreToolHookRuntime = NoopCoreToolHookRuntime(),
        initialContext!: ?InitialContextPreparationPort = None
    ) {
        this.model = ControlledModelPort(model)
        this.runs = runs
        this.tools = tools
        this.catalog = catalog
        this.modelAttemptRecovery = modelAttemptRecovery
        this.attemptClock = attemptClock
        this.toolHooks = toolHooks
        this.initialContext = initialContext
        this.threadRuntimes = match (threadRuntimes) {
            case Some(value) => value
            case None => InMemoryThreadRuntimeRegistry(
                ContextProjector("agent-core-v1", ConservativeThreadTokenEstimator()),
                { => agentUtcMillis() }
            )
        }
        this.operationRuntime = match (operationRuntime) {
            case Some(value) => value
            case None => tools.operationRuntime()
        }
        this.modelDecisionRuntime = match (modelDecisionRuntime) {
            case Some(value) => value
            case None => InMemoryModelDecisionRuntimePort()
        }
        this.contextManifestRuntime = match (contextManifestRuntime) {
            case Some(value) => value
            case None => InMemoryModelContextManifestRuntimePort()
        }
        this.model.bindBudgetController(AgentCoreInternalModelBudgetController(this))
    }

    public init(
        model: ControlledModelPort,
        runs: RunRepository,
        tools: ToolPipeline,
        catalog: ToolCatalog,
        threadRuntimes!: ?ThreadRuntimeRegistry = None,
        operationRuntime!: ?OperationRuntimePort = None,
        modelDecisionRuntime!: ?ModelDecisionRuntimePort = None,
        contextManifestRuntime!: ?ModelContextManifestRuntimePort = None,
        modelAttemptRecovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy(),
        attemptClock!: AttemptMonotonicClock = SystemAttemptMonotonicClock(),
        toolHooks!: CoreToolHookRuntime = NoopCoreToolHookRuntime(),
        initialContext!: ?InitialContextPreparationPort = None
    ) {
        this.model = model
        this.runs = runs
        this.tools = tools
        this.catalog = catalog
        this.modelAttemptRecovery = modelAttemptRecovery
        this.attemptClock = attemptClock
        this.toolHooks = toolHooks
        this.initialContext = initialContext
        this.threadRuntimes = match (threadRuntimes) {
            case Some(value) => value
            case None => InMemoryThreadRuntimeRegistry(
                ContextProjector("agent-core-v1", ConservativeThreadTokenEstimator()),
                { => agentUtcMillis() }
            )
        }
        this.operationRuntime = match (operationRuntime) {
            case Some(value) => value
            case None => tools.operationRuntime()
        }
        this.modelDecisionRuntime = match (modelDecisionRuntime) {
            case Some(value) => value
            case None => InMemoryModelDecisionRuntimePort()
        }
        this.contextManifestRuntime = match (contextManifestRuntime) {
            case Some(value) => value
            case None => InMemoryModelContextManifestRuntimePort()
        }
        this.model.bindBudgetController(AgentCoreInternalModelBudgetController(this))
    }

    public func prepareContinuation(request: AgentRunRequest): Result<CoreContinuationPreparation> {
        try { Result.Ok(CoreContinuationPreparation(request, coreModelLane(request, catalog))) }
        catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.InvalidInput, "continuation.request_invalid", "cannot freeze the continuation request")) }
    }

    public func startContinuation(value: AgentContinuationStart, sink: AgentEventSink): Result<AgentRunOutcome> {
        startOwned(value.preparation.request, sink, Some(value))
    }

    public func start(request: AgentRunRequest, sink: AgentEventSink): Result<AgentRunOutcome> {
        startOwned(request, sink, None)
    }
    public func startRestricted111(request: AgentRunRequest, restriction: AgentRunStartRestriction111,
        events: AgentEventSink): Result<AgentRunOutcome> {
        startOwned(request, events, None, restriction: Some(restriction))
    }

    private func startOwned(request: AgentRunRequest, sink: AgentEventSink,
        continuation: ?AgentContinuationStart, restriction!: ?AgentRunStartRestriction111 = None): Result<AgentRunOutcome> {
        let contextProjection = try {
            validatedContextSnapshot(request.contextSnapshot)
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "context.snapshot_invalid", error.message
            ))
        }
        let userBlocks = ArrayList<ModelBlock>()
        userBlocks.add(ModelBlock(ModelBlockKind.Text, text: request.prompt))
        for (image in request.imageInputs) {
            userBlocks.add(ModelBlock(ModelBlockKind.Image, image: Some(image)))
        }
        let user = ModelMessage(ModelRole.User, userBlocks.toArray())
        let runtime = match (threadRuntimes.acquire(
            ThreadId(request.sessionId.value),
            coreWorkspaceId(request)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // Publish the single-owner control before durable admission starts.
        // startTurn() creates the canonical Run before the compatibility
        // snapshot is visible, so registering afterwards leaves an early
        // cancellation able to misclassify that valid window as corruption.
        let control = CoreRunControl(request.runId, request.budget, runtime,
            parentCancellation: match (restriction) { case Some(value) => Some(value.cancellation); case None => None },
            callerCancellation180: request.callerCancellation180,
            recoveryPolicy180: modelAttemptRecoveryForSettings180(request.toolContext.executionSettings180, modelAttemptRecovery))
        match (controls.add(control)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                if (restriction.isSome()) { control.close() }
                return Result.Err(error)
        }
        control.bindCancellation(model, tools)
        let semanticTurnId = SemanticTurnId("turn-" + request.runId.value)
        let startLease: ?ToolExecutionHandoffLease = match (restriction) {
            case Some(value) => match (coreAcquireStartRestriction111(value, request)) {
                case Result.Err(error) => finishControl(request.runId); return Result.Err(error)
                case Result.Ok(lease) => Some(lease) }
            case None => None }
        var startRevalidationError: ?AgentError = None
        let startedRun = try {
            match (restriction) { case Some(value) => match (coreCheckStartRestriction111(value, request)) {
                case Result.Err(error) => finishControl(request.runId); return Result.Err(error)
                case Result.Ok(_) => () }; case None => () }
            let result = match (continuation) {
            case Some(value) => runtime.startContinuationTurn(value.admission, value.preparation.requestSnapshot(),
                value.preparation.lane, request.contextSnapshot, coreBudgetSnapshot(request.budget),
                createdAtMillis: agentUtcMillis(), deadlineMillis: request.budget.deadlineMillis,
                parentCancellation: Some(control.source.token))
            case None => startTurnWithPrivateLane159(runtime, request, semanticTurnId, user, control)
            }
            if (result.isOk()) { match (restriction) {
                case Some(value) => match (coreCheckStartRestriction111(value, request)) {
                    case Result.Err(error) => startRevalidationError = Some(error); case Result.Ok(_) => () }
                case None => () } }
            result
        } finally { match (startLease) { case Some(value) => value.close(); case None => () } }
        let active = match (startedRun) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                finishControl(request.runId)
                return Result.Err(error)
        }
        try {
            startAcceptedRunFrame159(request, sink, continuation, restriction,
                contextProjection, user, runtime, control, active, startRevalidationError)
        } finally {
            // The real enclosing helper returned or threw. Deferred Contexts
            // keep independent paid shares; a failure cannot skip this view.
            active.returnOwnedLaneView159()
        }
    }
    private func startAcceptedRunFrame159(request: AgentRunRequest, sink: AgentEventSink,
        continuation: ?AgentContinuationStart, restriction: ?AgentRunStartRestriction111,
        contextProjection: InvocationContextProjection, user: ModelMessage,
        runtime: AgentThreadRuntime, control: CoreRunControl, active: ActiveRunSnapshot,
        startRevalidationError: ?AgentError): Result<AgentRunOutcome> {
        let transition = RunTransition(
            active.transitionSequence,
            RunState.Created,
            RunState.Running,
            "run started"
        )
        let initial = RunSnapshot(
            request.runId,
            request.sessionId,
            RunState.Running,
            summary: "run started"
        )
        match (runs.save(initial)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = runtime.finish(
                    RunState.Failed,
                    1000,
                    reason: "initial run snapshot persistence failed"
                )
                finishControl(request.runId)
                return Result.Err(error)
        }
        let toolOutputSink = CoreToolOutputSink()
        let context = ToolInvocationContext(
            request.runId,
            request.sessionId,
            request.capabilities,
            epoch: active.epoch,
            toolContext: request.toolContext,
            cancellation: control.source.token,
            approvalModeOverride: request.approvalModeOverride,
            outputSink: toolOutputSink,
            budget: control.ledger,
            budgetModeFn: Some({ => control.budgetMode() }),
            contextProjection: contextProjection,
            toolSetSnapshot: active.lane.legacyToolSetSnapshot159(),
            ownedToolSetSnapshot159: active.lane.forkOwnedToolSetSnapshot159()
        )
        bindToolOutputSink(context, control, sink, toolOutputSink)
        bindBudgetChargeHandler(context, control, sink)
        match (emitTyped(context, control, AgentEventPayload.RunStarted, sink)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(request, context, control, error, sink)
        }
        match (emitTransition(context, control, transition, sink)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(request, context, control, error, sink)
        }
        // The physical restriction ended before any provider/UI call. A
        // post-admission cancellation still has a real Run and must use the
        // existing durable failure/cleanup route; it is never erased or retried.
        match (startRevalidationError) { case Some(error) => return fail(request, context, control, error, sink); case None => () }
        match (restriction) { case Some(value) => match (coreNotifyStartRestriction111(value, request)) {
            case Result.Err(error) => return fail(request, context, control, error, sink); case Result.Ok(_) => () }; case None => () }
        if (request.initializeContext) {
            let port = match (initialContext) { case Some(value) => value
                case None => return fail(request, context, control, AgentError(AgentErrorKind.RecoveryRequired,
                    "context.initial_preparation_unavailable", "host did not install an initial context preparer"), sink) }
            // This open port can retain its snapshot. It gets an independent
            // paid view; only a separate explicit returning port may retire it.
            let captured = try { port.prepare(request, context, active.forkIndependentView159()) } catch (_: Exception) {
                Result<InitialContextPreparation>.Err(AgentError(AgentErrorKind.Internal,
                    "context.initial_preparation_failed", "host initial context preparation failed")) }
            let preparation = match (captured) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(request, context, control, error, sink) }
            match (runs.bindAcceptedContextRequest(request.runId, request.sessionId, active.epoch,
                if (continuation.isSome()) { ThreadItemContent.SystemNote("Host continuation") } else { coreUserContent(user) },
                initialContextRequestValue(request, active.epoch), agentUtcMillis())) {
                case Result.Err(error) => return fail(request, context, control, error, sink)
                case Result.Ok(_) => () }
            match (queueContextReadUpdate(request.runId, active.epoch,
                contextReadProjectionDigest(context.contextProjection), preparation.read, validity: preparation.validity,
                sequence: preparation.sequence, requiredBeforeModel: true)) {
                case Result.Err(error) => return fail(request, context, control, error, sink)
                case Result.Ok(_) => () }
        }
        continueRun(request, context, control, BudgetCounter(), sink)
    }

    private func startTurnWithPrivateLane159(runtime: AgentThreadRuntime, request: AgentRunRequest,
        semanticTurnId: SemanticTurnId, user: ModelMessage, control: CoreRunControl): Result<ActiveRunSnapshot> {
        let lane = coreModelLane(request, catalog)
        let result = startTurnWithPrivateLaneFrame159(runtime, request, semanticTurnId, user, control, lane)
        // Runtime forked its own lane before admission; no input-lane reference
        // is published in its result or retained by the concrete start helper.
        lane.returnOwnedLaneFrame159()
        result
    }
    private func startTurnWithPrivateLaneFrame159(runtime: AgentThreadRuntime, request: AgentRunRequest,
        semanticTurnId: SemanticTurnId, user: ModelMessage, control: CoreRunControl,
        lane: ModelLane): Result<ActiveRunSnapshot> {
        runtime.startTurn(semanticTurnId, request.runId,
            match (request.queuedInitiator113) { case Some(value) => ItemId(value.entryId.value); case None => ItemId("user-" + request.runId.value) },
            coreUserContent(user), lane, request.contextSnapshot, executionLaneId: request.executionLaneId,
            createdAtMillis: agentUtcMillis(), deadlineMillis: request.budget.deadlineMillis,
            parentCancellation: Some(control.source.token), runBudgetSnapshot: coreBudgetSnapshot(request.budget),
            queuedInitiator113: request.queuedInitiator113, queuedInputPayment113: request.queuedInputPayment113)
    }

    public func start(request: AgentRunRequest): Result<AgentRunOutcome> {
        start(request, {_ => ()})
    }

    public func resumeContextBoundary(request: AgentRunRequest, sink: AgentEventSink): Result<AgentRunOutcome> {
        // Ignore caller continuation data: read the actual current row first.
        let boundary = match (runs.contextBoundary(request.runId)) {
            case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return Result.Err(coreContextBoundaryError("no current context boundary"))
            case Result.Err(error) => return Result.Err(error) }
        let data = boundary.data()
        let durable = try { coreContextBoundaryRequestFromValue(contextBoundaryField(data, "request"), interactions: request.interactions, ownedEvents: request.ownedEvents, callerCancellation180: request.callerCancellation180) }
            catch (error: Exception) { return Result.Err(coreContextBoundaryError(error.message)) }
        if (durable.runId.value != request.runId.value || durable.sessionId.value != request.sessionId.value ||
            durable.resolverVersion != MODEL_POLICY_RESOLUTION_VERSION ||
            durable.modelCapabilitiesSnapshot.snapshotSchemaVersion != MODEL_CAPABILITY_SNAPSHOT_VERSION ||
            controls.find(durable.runId).isSome() ||
            (durable.budget.deadlineMillis > 0 && agentUtcMillis() >= durable.budget.deadlineMillis)) {
            return Result.Err(coreContextBoundaryError("boundary is cancelled, expired, already owned, or incompatible")) }
        let snapshot = match (runs.find(durable.runId)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let usage = contextBoundaryUsage(contextBoundaryField(data, "usage"))
        let counter = try { coreContextBoundaryCounter(contextBoundaryField(data, "counter"), restoredWallStart: Some(contextBoundaryInteger(data, "wall_start_millis"))) }
            catch (error: Exception) { return Result.Err(coreContextBoundaryError(error.message)) }
        if (durable.budget.maxWallMillis > 0 &&
            (MonoTime.now() - counter.startedAt).toMilliseconds() >= durable.budget.maxWallMillis) {
            return Result.Err(coreContextBoundaryError("original wall-time budget expired during restart")) }
        let state = try { coreContextBoundaryToolState(contextBoundaryField(data, "tool_loop_state")) }
            catch (error: Exception) { return Result.Err(coreContextBoundaryError(error.message)) }
        if (usage.turns != counter.turns || usage.modelRequests != counter.workModelRequests ||
            usage.drainModelRequests != counter.drainModelRequests || usage.inputTokens != counter.inputTokens ||
            usage.outputTokens != counter.outputTokens || usage.toolCalls != counter.toolCalls || usage.activeTools != 0) {
            return Result.Err(coreContextBoundaryError("full boundary counter and ledger disagree")) }
        let control = match (controlForResume(durable, snapshot, modelRecovery: true, initialUsage: Some(usage))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        try { control.restoreContextBoundaryControl(contextBoundaryField(data, "control")) }
            catch (error: Exception) { finishControl(durable.runId); return Result.Err(coreContextBoundaryError(error.message)) }
        let active = control.runtime.activeRun().getOrThrow()
        if (active.epoch != contextBoundaryInteger(data, "epoch") || active.executionLaneId.value != boundary.continuation.laneId.value ||
            contextReadProjectionDigest(active.contextSnapshot) != contextBoundaryText(data, "context_digest") ||
            contextReadProjectionDigest(durable.contextSnapshot) != contextBoundaryText(data, "context_digest") ||
            !active.lane.snapshotDigestEquals159(contextBoundaryText(data, "lane_digest"))) {
            finishControl(durable.runId); return Result.Err(coreContextBoundaryError("actual recovered Thread enclosure changed")) }
        if (!coreCatalogMatchesLane159(catalog, active.lane, durable.capabilities, ThreadId(durable.sessionId.value))) {
            finishControl(durable.runId); return Result.Err(coreContextBoundaryError("current catalog changed since the frozen context cut")) }
        control.requireContextBoundaryPrepare()
        let sequence = match (runs.events(durable.runId, snapshot.sequence)) {
            case Result.Ok(page) => max(snapshot.sequence, page.nextSequence - 1)
            case Result.Err(error) => finishControl(durable.runId); return Result.Err(error) }
        let output = CoreToolOutputSink()
        let context = ToolInvocationContext(durable.runId, durable.sessionId, durable.capabilities, sequence: sequence,
            epoch: active.epoch, toolContext: durable.toolContext, cancellation: control.source.token,
            approvalModeOverride: durable.approvalModeOverride, outputSink: output, budget: control.ledger,
            budgetModeFn: Some({ => control.budgetMode() }), contextProjection: active.contextSnapshot,
            toolSetSnapshot: active.lane.legacyToolSetSnapshot159(),
            ownedToolSetSnapshot159: active.lane.forkOwnedToolSetSnapshot159())
        bindToolOutputSink(context, control, sink, output)
        bindBudgetChargeHandler(context, control, sink)
        continueRun(durable, context, control, counter, sink, toolLoopState: Some(state),
            resumedPaidTurn: contextBoundaryText(data, "point") == "turn_reserved")
    }

    public func resume(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let continuation = match (runs.continuation(request.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (continuation.kind != RunContinuationKind.RunningModel) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.model_continuation_kind_invalid",
                "durable continuation is not a running model execution"
            ))
        }
        let checkpoint = match (continuation.runningModel) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.model_checkpoint_missing",
                "running model continuation has no checkpoint"
            ))
        }
        if (continuation.resolverVersion != MODEL_POLICY_RESOLUTION_VERSION ||
            match (continuation.modelCapabilitiesSnapshot) {
                case Some(value) => value.snapshotSchemaVersion != MODEL_CAPABILITY_SNAPSHOT_VERSION
                case None => true
            }) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.model_policy_version_unsupported",
                "durable model policy or capability snapshot version is unsupported"
            ))
        }
        if (modelPolicySha256Text(canonicalAgentValue(checkpoint.canonicalRequest)) !=
            checkpoint.semanticRequestDigest) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.checkpoint_digest_mismatch",
                "durable model request checkpoint failed integrity validation"
            ))
        }
        let durableRequest = try { requestFromContinuation(
            continuation, interactions: request.interactions,
            toolContext: request.toolContext
        ) } catch (_: Exception) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.snapshot_unsupported_or_invalid",
                "durable recovery request contains an unsupported or invalid context snapshot"))
        }
        let contextProjection = try {
            validatedContextSnapshot(durableRequest.contextSnapshot)
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired, "context.snapshot_invalid", error.message
            ))
        }
        let snapshot = match (runs.find(durableRequest.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // The exact pre-HTTP policy/dispatch events are committed independently
        // of the product Run snapshot. Resume from the durable event head so a
        // restarted process cannot reuse an already committed sequence number.
        let resumeSequence = match (runs.events(
            durableRequest.runId, snapshot.sequence
        )) {
            case Result.Ok(page) => max(snapshot.sequence, page.nextSequence - 1)
            case Result.Err(error) => return Result.Err(error)
        }
        let control = match (controlForResume(
            durableRequest, snapshot, modelRecovery: true,
            initialUsage: Some(ExecutionUsage(
                turns: checkpoint.turns,
                modelRequests: checkpoint.workModelRequests,
                drainModelRequests: checkpoint.drainModelRequests,
                toolCalls: checkpoint.toolCalls,
                inputTokens: checkpoint.inputTokens,
                outputTokens: checkpoint.outputTokens,
                costMicros: match (checkpoint.costMicros) {
                    case Some(value) => value
                    case None => 0
                }
            ))
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // Restore the request's actual budget class before any replay charge.
        // A checkpoint can be taken on the last ordinary work turn, so turns
        // alone cannot infer whether the next request is work or drain.
        if (checkpoint.requestBudgetClass == BudgetChargeClass.Drain) {
            control.restoreDraining()
        }
        let runToolSet = match (coreActiveRunToolLane159(control.runtime)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let toolOutputSink = CoreToolOutputSink()
        let context = ToolInvocationContext(
            durableRequest.runId, durableRequest.sessionId,
            durableRequest.capabilities, sequence: resumeSequence,
            epoch: coreOwnedControlMetadata(control.runtime).activeEpoch,
            toolContext: durableRequest.toolContext,
            cancellation: control.source.token,
            approvalModeOverride: durableRequest.approvalModeOverride,
            outputSink: toolOutputSink,
            budget: control.ledger,
            budgetModeFn: Some({ => control.budgetMode() }),
            contextProjection: contextProjection,
            toolSetSnapshot: runToolSet.legacyToolSetSnapshot159(),
            ownedToolSetSnapshot159: runToolSet.forkOwnedToolSetSnapshot159()
        )
        runToolSet.returnOwnedLaneFrame159()
        bindToolOutputSink(context, control, sink, toolOutputSink)
        bindBudgetChargeHandler(context, control, sink)
        let counter = BudgetCounter(
            modelRequests: checkpoint.modelRequests,
            workModelRequests: checkpoint.workModelRequests,
            drainModelRequests: checkpoint.drainModelRequests,
            inputTokens: checkpoint.inputTokens,
            outputTokens: checkpoint.outputTokens,
            reasoningTokens: checkpoint.reasoningTokens,
            cacheReadTokens: checkpoint.cacheReadTokens,
            cacheWriteTokens: checkpoint.cacheWriteTokens,
            costMicros: checkpoint.costMicros,
            lastInputTokens: checkpoint.lastInputTokens,
            lastOutputTokens: checkpoint.lastOutputTokens,
            lastRequestDurationMillis: checkpoint.lastRequestDurationMillis,
            toolCalls: checkpoint.toolCalls,
            turns: checkpoint.turns
        )
        let resumedToolState = CoreToolLoopState()
        resumedToolState.consecutiveCapabilityDenials =
            checkpoint.consecutiveCapabilityDenials
        resumedToolState.lastCapabilityDeniedTool =
            checkpoint.lastCapabilityDeniedTool
        let storedAttempt = match (runs.modelAttempt(checkpoint.activeAttemptId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        if (storedAttempt.transcriptSnapshot == "" ||
            !model.validateTranscriptSnapshot(storedAttempt.transcriptSnapshot)) {
            return fail(
                durableRequest, context, control,
                AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "model.attempt_replay_binding_invalid",
                    "durable model Attempt transcript snapshot is missing or cannot be restored"
                ), sink, counter: Some(counter)
            )
        }
        if (storedAttempt.semanticRequestDigest != checkpoint.semanticRequestDigest ||
            storedAttempt.wirePolicyDigest != checkpoint.wirePolicyDigest ||
            storedAttempt.semanticRequestId.value != checkpoint.semanticRequestId.value) {
            return fail(
                durableRequest, context, control,
                AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "model.attempt_replay_binding_invalid",
                    "durable model Attempt does not match its frozen checkpoint"
                ), sink, counter: Some(counter)
            )
        }
        match (modelDecisionRuntime.uncommittedDecision(durableRequest.runId)) {
            case Result.Ok(Some(decision)) =>
                let recovered = recoveredDurableModelResult(decision)
                if (decision.attemptId.value != storedAttempt.id.value ||
                    decision.semanticRequestId.value != storedAttempt.semanticRequestId.value) {
                    return fail(
                        durableRequest, context, control,
                        AgentError(
                            AgentErrorKind.RecoveryRequired,
                            "model.decision_attempt_binding_invalid",
                            "durable Model Decision does not match the active checkpoint"
                        ), sink, counter: Some(counter)
                    )
                }
                match (storedAttempt.replayBarrier) {
                    case ModelAttemptReplayBarrier.NoBarrier => match (markModelAttemptBarrier(
                        decision.attemptId, decision.semanticRequestId,
                        ModelAttemptReplayBarrier.ProviderTerminal,
                        context, control, sink
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return fail(
                            durableRequest, context, control, error, sink,
                            counter: Some(counter)
                        )
                    }
                    case ModelAttemptReplayBarrier.ProviderTerminal |
                        ModelAttemptReplayBarrier.ToolEvidence => ()
                    case _ => return fail(
                        durableRequest, context, control,
                        AgentError(
                            AgentErrorKind.RecoveryRequired,
                            "model.decision_replay_barrier_invalid",
                            "durable Model Decision has an incompatible replay barrier"
                        ), sink, counter: Some(counter)
                    )
                }
                match (reserveBudget(
                    control, context, BudgetCharge(modelRequests: 1), sink
                )) {
                    case Result.Ok(_) =>
                        counter.recordModelRequest(control.budgetMode())
                    case Result.Err(error) => return fail(
                        durableRequest, context, control, error, sink,
                        counter: Some(counter)
                    )
                }
                match (accountRecoveredReply(
                    durableRequest, recovered.reply, checkpoint, counter,
                    context, control, sink
                )) {
                    case Result.Ok(_) => return continueRun(
                        durableRequest, context, control, counter, sink,
                        toolLoopState: Some(resumedToolState)
                    )
                    case Result.Err(error) => return fail(
                        durableRequest, context, control, error, sink,
                        counter: Some(counter)
                    )
                }
            case Result.Ok(None) => ()
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        if (storedAttempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
            return fail(
                durableRequest, context, control,
                AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "model.attempt_replay_binding_invalid",
                    "durable model Attempt is not safe to resume"
                ), sink, counter: Some(counter)
            )
        }
        var attemptId = storedAttempt.id
        var attemptNo = storedAttempt.attemptNo
        var executionPolicyReason = storedAttempt.policyReason
        var modelRequest = match (modelRequestFromCheckpoint(
            checkpoint.canonicalRequest, checkpoint.stableRequestId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        if (storedAttempt.transcriptSnapshot != "") {
            let regeneratedSnapshot = match (model.transcriptSnapshot(modelRequest)) {
                case Some(value) => value
                case None => ""
            }
            if (regeneratedSnapshot != storedAttempt.transcriptSnapshot) {
                return fail(
                    durableRequest, context, control,
                    AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "model.attempt_replay_binding_invalid",
                        "current model adapter does not reproduce the frozen transcript snapshot"
                    ), sink, counter: Some(counter)
                )
            }
        }
        if (storedAttempt.dispatchState == ModelAttemptDispatchState.DispatchClaimed) {
            if (!durableRequest.autoRetry || !control.recoveryPolicy180.enabled() ||
                control.recoveryPolicy180.maxRecoveryRetries == 0 || storedAttempt.attemptNo != 1 ||
                (durableRequest.budget.deadlineMillis > 0 &&
                    agentUtcMillis() >= durableRequest.budget.deadlineMillis)) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "model.restart_retry_not_allowed",
                    "dispatched model Attempt cannot be replayed under the frozen recovery policy"
                ))
            }
            attemptNo = 2
            attemptId = modelAttemptIdFor(checkpoint.semanticRequestId, attemptNo)
            modelRequest = modelRequestForAttempt(modelRequest, attemptNo)
            let policy = attemptPolicyFor(
                modelRequest, AttemptPolicyReason.Retry, control.recoveryPolicy180
            )
            executionPolicyReason = attemptPolicyReasonName(policy.reason)
            match (persistModelAttemptBeforeRequest(
                durableRequest, checkpoint.semanticRequestId, attemptId, attemptNo,
                Some(storedAttempt.id), policy, modelRequest, counter,
                context, control, sink, resumedToolState,
                restartParent: Some(storedAttempt)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return if (
                    error.kind == AgentErrorKind.RecoveryRequired
                ) { Result.Err(error) } else {
                    fail(
                        durableRequest, context, control, error, sink,
                        counter: Some(counter)
                    )
                }
            }
        } else if (storedAttempt.dispatchState != ModelAttemptDispatchState.Prepared) {
            return fail(
                durableRequest, context, control,
                AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "model.attempt_dispatch_state_unknown",
                    "unrecognized model Attempt dispatch state cannot be replayed"
                ), sink, counter: Some(counter)
            )
        }
        match (reserveBudget(
            control, context, BudgetCharge(), sink,
            requestId: Some(RequestId(modelRequest.requestId))
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        match (reserveBudget(
            control, context, BudgetCharge(modelRequests: 1), sink,
            requestId: Some(RequestId(modelRequest.requestId))
        )) {
            case Result.Ok(_) =>
                counter.recordModelRequest(control.budgetMode())
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        match (claimModelAttemptBeforeRequest(
            attemptId, checkpoint.semanticRequestId, context, control, sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return if (
                error.kind == AgentErrorKind.RecoveryRequired
            ) { Result.Err(error) } else {
                fail(
                    durableRequest, context, control, error, sink,
                    counter: Some(counter)
                )
            }
        }
        let dispatched = match (dispatchClaimedModelAttempt(
            durableRequest, counter, modelRequest, attemptNo,
            checkpoint.semanticRequestId, attemptId, executionPolicyReason,
            context, control, sink
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
        let execution = dispatched.execution
        let started = dispatched.startedAt
        let result = execution.result
        match (settleProvisionalModelEvents(
            execution.provisionalEvents, true, context, control,
            checkpoint.semanticRequestId, attemptId, sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink,
                counter: Some(counter)
            )
        }
        let durable = recordDurableDecisionLifecycle(
            durableResultForAttempt(
                durableRequest, checkpoint.semanticRequestId, attemptId, result
            ),
            context, control, checkpoint.semanticRequestId, attemptId, sink
        )
        match (durable) {
            case Result.Ok(value) =>
                match (accountRecoveredReply(
                    durableRequest, value.reply, checkpoint, counter,
                    context, control, sink,
                    durationMillis: max(0, (MonoTime.now() - started).toMilliseconds()),
                    usageRequestId: modelRequest.requestId
                )) {
                    case Result.Ok(_) => continueRun(
                        durableRequest, context, control, counter, sink,
                        toolLoopState: Some(resumedToolState)
                    )
                    case Result.Err(error) => fail(
                        durableRequest, context, control, error, sink,
                        counter: Some(counter)
                    )
                }
            case Result.Err(error) => fail(
                durableRequest, context, control, error, sink, counter: Some(counter)
            )
        }
    }

    public func resume(request: AgentRunRequest): Result<AgentRunOutcome> {
        resume(request, {_ => ()})
    }

    private func accountRecoveredReply(
        request: AgentRunRequest,
        reply: ModelReply,
        checkpoint: RunningModelCheckpoint,
        counter: BudgetCounter,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        durationMillis!: Int64 = -1,
        usageRequestId!: String = ""
    ): Result<Unit> {
        let duration = if (durationMillis >= 0) {
            durationMillis
        } else {
            max(0, agentUtcMillis() - checkpoint.requestStartedAtMillis)
        }
        let observedUsage = accountedModelAttemptUsage(reply, request.pricing)
        match (counter.accountReply(reply, request.budget, request.pricing, duration)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = control.ledger.recordObservedUsage(observedUsage)
                return Result.Err(error)
        }
        let cost = match (observedUsage.costMicros) {
            case Some(value) => value
            case None => 0
        }
        let stableRequestId = RequestId(if (usageRequestId == "") {
            checkpoint.stableRequestId
        } else { usageRequestId })
        match (reserveBudget(
            control,
            context,
            BudgetCharge(
                inputTokens: reply.inputTokens,
                outputTokens: reply.outputTokens,
                costMicros: cost
            ),
            sink,
            requestId: Some(stableRequestId),
            observedUsage: Some(observedUsage)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        emitTyped(
            context,
            control,
            AgentEventPayload.ModelUsageUpdated(observedUsage),
            sink,
            requestId: Some(stableRequestId)
        )
    }

    // Read-only canonical inspection for SDKs, headless adapters, and tests.
    public func threadSnapshot(sessionId: SessionId): Result<AgentThreadSnapshot> {
        match (threadRuntimes.acquire(
            ThreadId(sessionId.value), "agent-core"
        )) {
            case Result.Ok(runtime) => Result.Ok(runtime.threadSnapshot())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let previous = match (runs.find(request.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!isAwaitingApproval(previous.status) &&
            previous.status != RunState.Completed) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "run.not_awaiting_approval",
                    "run is not waiting for an approval decision"
                )
            )
        }
        let continuation = match (runs.continuation(request.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = runs.save(RunSnapshot(
                    previous.runId,
                    previous.sessionId,
                    RunState.RecoveryRequired,
                    sequence: previous.sequence,
                    summary: error.message,
                    error: Some(error),
                    modelRequests: previous.modelRequests,
                    usage: previous.usage,
                    lastInputTokens: previous.lastInputTokens,
                    lastOutputTokens: previous.lastOutputTokens,
                    lastRequestDurationMillis: previous.lastRequestDurationMillis,
                    toolCalls: previous.toolCalls,
                    turns: previous.turns,
                    kind: previous.kind
                ))
                return Result.Err(error)
        }
        match (validateApprovalContinuation(request, approval, continuation)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let durableApproval = continuation.approval
        let durableRequest = try { requestFromContinuation(
            continuation,
            interactions: request.interactions,
            toolContext: request.toolContext
        ) } catch (_: Exception) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.snapshot_unsupported_or_invalid",
                "durable recovery request contains an unsupported or invalid context snapshot"))
        }
        let contextProjection = try {
            validatedContextSnapshot(durableRequest.contextSnapshot)
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired, "context.snapshot_invalid", error.message
            ))
        }
        // Validate current targets and approval scope before consuming the decision.
        if (isAwaitingApproval(previous.status)) {
            let preflightControl = match (controlForResume(durableRequest, previous)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let preflightToolSet = match (coreActiveRunToolLane159(preflightControl.runtime)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            var preflightSequence = previous.sequence
            match (runs.events(durableRequest.runId, 0)) {
                case Result.Ok(page) =>
                    preflightSequence = max(preflightSequence, page.nextSequence - 1)
                    for (event in page.events) {
                        preflightSequence = max(preflightSequence, event.sequence)
                    }
                case Result.Err(_) => ()
            }
            let preflightContext = ToolInvocationContext(
                durableRequest.runId,
                durableRequest.sessionId,
                durableRequest.capabilities,
                sequence: preflightSequence,
                epoch: coreOwnedControlMetadata(preflightControl.runtime).activeEpoch,
                toolContext: durableRequest.toolContext,
                cancellation: preflightControl.source.token,
                approvalModeOverride: durableRequest.approvalModeOverride,
                budget: preflightControl.ledger,
                budgetModeFn: Some({ => preflightControl.budgetMode() }),
                contextProjection: contextProjection,
                toolSetSnapshot: preflightToolSet.legacyToolSetSnapshot159(),
                ownedToolSetSnapshot159: preflightToolSet.forkOwnedToolSetSnapshot159()
            )
            preflightToolSet.returnOwnedLaneFrame159()
            let retainedOwned = preflightControl.pendingOwnedExecutionFor(durableApproval.operationId)
            let retainedParent = preflightControl.pendingOwnedParentFor(durableApproval.operationId)
            if (retainedOwned.isNone() && retainedParent.isNone()) {
                let requiresOwner = match (tools.requiresOwnedApprovalOwner(preflightContext,durableApproval.operationId)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (requiresOwner) { return Result.Err(coreOwnedLiveOwnerMissing()) }
            }
            let validation = if (retainedOwned.isSome()) {
                tools.validateRetainedOwnedExecutionDecision(preflightContext,
                    retainedOwned.getOrThrow().publication,durableApproval,decision)
            } else if (retainedParent.isSome()) {
                tools.validateRetainedOwnedParentDecision(preflightContext,
                    retainedParent.getOrThrow().work.prepared,durableApproval,decision)
            } else if (durableApproval.toolName == HOST_PLUGIN_LIVE_EFFECT_TOOL) {
                Result<Unit>.Err(coreOwnedLiveOwnerMissing())
            } else if (durableApproval.toolName == HOST_CONTEXT_READ_TOOL) {
                match (preflightControl.pendingRead(durableApproval.operationId)) {
                    case Some(value) => tools.validateRetainedContextReadDecision(preflightContext, value.prepared, decision)
                    case None => Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "context.read_live_owner_missing", "read approval requires its original live owner; recovery cannot mint it"))
                }
            } else {
                let committed = match (committedToolCallFor(preflightControl, durableApproval.callId)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                match (preflightControl.preparationInput(committed.canonicalItemId)) {
                    case Some(owner) => match (owner.read) {
                        case Some(read) => tools.validateReadBackedApprovalDecision(preflightContext,
                            durableApproval.operationId, committed, read, decision)
                        case None => tools.validateApprovalDecision(preflightContext, durableApproval.operationId, decision) }
                    case None => tools.validateApprovalDecision(preflightContext, durableApproval.operationId, decision) }
            }
            match (validation) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let decisionReceipt = ApprovalDecisionReceipt(
            durableApproval.operationId,
            durableRequest.runId,
            durableRequest.sessionId,
            durableApproval.callId,
            durableApproval.argumentHash,
            decision
        )
        let decisionSnapshot = match (runs.recordDecision(decisionReceipt)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (decisionSnapshot.status == RunState.Completed) {
            return Result.Ok(AgentRunOutcome.Completed(decisionSnapshot))
        }
        if (!isAwaitingApproval(decisionSnapshot.status)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "run.not_awaiting_approval",
                "run is not waiting for an approval decision"
            ))
        }
        var sequence = decisionSnapshot.sequence
        match (runs.events(durableRequest.runId, 0)) {
            case Result.Ok(page) =>
                sequence = max(sequence, page.nextSequence - 1)
                for (event in page.events) {
                    sequence = max(sequence, event.sequence)
                }
            case Result.Err(_) => ()
        }
        let control = match (controlForResume(durableRequest, decisionSnapshot)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let runToolSet = match (coreActiveRunToolLane159(control.runtime)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let toolOutputSink = CoreToolOutputSink()
        let context = ToolInvocationContext(
            durableRequest.runId,
            durableRequest.sessionId,
            durableRequest.capabilities,
            sequence: sequence,
            epoch: coreOwnedControlMetadata(control.runtime).activeEpoch,
            toolContext: durableRequest.toolContext,
            cancellation: control.source.token,
            approvalModeOverride: durableRequest.approvalModeOverride,
            outputSink: toolOutputSink,
            budget: control.ledger,
            budgetModeFn: Some({ => control.budgetMode() }),
            contextProjection: contextProjection,
            toolSetSnapshot: runToolSet.legacyToolSetSnapshot159(),
            ownedToolSetSnapshot159: runToolSet.forkOwnedToolSetSnapshot159()
        )
        runToolSet.returnOwnedLaneFrame159()
        bindToolOutputSink(context, control, sink, toolOutputSink)
        bindBudgetChargeHandler(context, control, sink)
        let resumed = match (control.resumeAfterApproval()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest,
                context,
                control,
                error,
                sink
            )
        }
        match (emitTransition(context, control, resumed, sink)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                durableRequest,
                context,
                control,
                error,
                sink
            )
        }
        match (control.pendingOwnedExecutionFor(durableApproval.operationId)) {
            case Some(value) => return resumeOwnedExecutionApproval(durableRequest,context,control,
                decisionSnapshot,durableApproval,decision,value,sink)
            case None => ()
        }
        match (control.pendingOwnedParentFor(durableApproval.operationId)) {
            case Some(value) => return resumeOwnedParentApproval(durableRequest,context,control,
                decisionSnapshot,durableApproval,decision,value,sink)
            case None => ()
        }
        if (durableApproval.toolName == HOST_CONTEXT_READ_TOOL) {
            return resumeContextReadApproval(durableRequest, context, control, decisionSnapshot, durableApproval, decision, sink)
        }
        let approvedPlan = match (tools.approvalPlan(
            context, durableApproval.operationId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink
            )
        }
        let committedApproval = match (committedToolCallFor(
            control, durableApproval.callId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink
            )
        }
        let executionHandoff = CoreExecutionHandoffState()
        let decide = { => tools.decideCommitted(
            context, durableApproval.operationId, committedApproval, decision,
            { _ => executionHandoff.started = true; Result.Ok(()) },
            decisionSource: durableApproval.decisionSource
        ) }
        let outcomeAttempt = if (isRejectedDecision(decision)) { decide() } else {
            withApprovalToolSlot(context, control, durableApproval.operationId,
                committedApproval.block.name, sink, decide)
        }
        let outcome = match (outcomeAttempt) {
            case Result.Ok(value) => canonicalRootToolResult(durableApproval.operationId, value)
            case Result.Err(error) => if (isRejectedDecision(decision) && error.code == "tool.operation_already_failed") {
                rejectedOutcome(durableApproval, decision)
            } else if (error.kind == AgentErrorKind.RecoveryRequired &&
                error.code == "tool.pending_registration_missing" &&
                !executionHandoff.started && !approvedPlan.contextReadFacts.isEmpty() &&
                match (control.preparationInput(committedApproval.canonicalItemId)) {
                    case Some(owner) => owner.read.isSome()
                    case None => false
                }) {
                // The original live read-backed review was validated before its
                // decision was recorded. decideCommitted has verified the exact
                // stored parent before finding its frozen implementation absent.
                // Preserve that cause and settle only this unexecuted parent;
                // the original canonical Prepared CAS still rejects a handoff race.
                ToolInvocationResult.Denied(ToolDenial(
                    committedApproval.block.callId, committedApproval.block.name, error
                ))
            } else {
                let failed = CoreToolOutcome(
                    0,
                    committedApproval,
                    Result.Err(error),
                    operationId: Some(durableApproval.operationId),
                    operationPlan: Some(approvedPlan),
                    attemptStage: if (executionHandoff.started) {
                        OperationAttemptStage.Executing
                    } else {
                        OperationAttemptStage.Prepared
                    }
                )
                match (commitCanonicalToolAttempt(control, failed)) {
                    case Result.Ok(_) => notifyPostToolHook(context, failed)
                    case Result.Err(commitError) =>
                        let diagnostic = AgentError(
                            commitError.kind,
                            commitError.code,
                            commitError.message + "; original tool error: " +
                                error.code + " (" + error.message + ")",
                            retryable: commitError.retryable,
                            fallbackAllowed: commitError.fallbackAllowed,
                            fields: commitError.fields,
                            attemptFailure: commitError.attemptFailure
                        )
                        return fail(
                            durableRequest, context, control, diagnostic, sink
                        )
                }
                return fail(durableRequest, context, control, error, sink)
            }
        }
        let resumedToolState = CoreToolLoopState()
        try {
        let canonicalOutcome = CoreToolOutcome(
            0,
            committedApproval,
            Result.Ok(outcome),
            operationId: Some(durableApproval.operationId),
            operationPlan: Some(approvedPlan),
            attemptStage: if (executionHandoff.started) {
                OperationAttemptStage.Executing
            } else {
                OperationAttemptStage.Prepared
            }
        )
        match (commitCanonicalToolAttempt(control, canonicalOutcome)) {
            case Result.Ok(_) => notifyPostToolHook(context, canonicalOutcome)
            case Result.Err(error) => return fail(
                durableRequest, context, control, error, sink
            )
        }
        control.releasePreparationInput(committedApproval.canonicalItemId)
        match (emitDetail(
            context,
            AgentEventKind.Approval,
            approvalDecisionEventValue(
                sourcedApprovalRequest(durableApproval, approval.decisionSource),
                decision
            ),
            sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (emitToolOutcome(
            context,
            durableApproval.toolName,
            outcome,
            approvedPlan.canonicalArguments,
            sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                durableRequest,
                context,
                control,
                error,
                sink
            )
        }
        match (afterCoreResultPersistedOwned113(
            context,
            control,
            durableApproval.toolName,
            outcome,
            Some(approvedPlan)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                durableRequest,
                context,
                control,
                error,
                sink
            )
        }
        updateCoreToolLoopState(resumedToolState, durableApproval.toolName, outcome)
        } finally { releaseToolInvocationPayload(Result.Ok(outcome)) }
        let resumedCounter = BudgetCounter(
            modelRequests: decisionSnapshot.modelRequests,
            inputTokens: decisionSnapshot.inputTokens,
            outputTokens: decisionSnapshot.outputTokens,
            reasoningTokens: decisionSnapshot.reasoningTokens,
            cacheReadTokens: decisionSnapshot.cacheReadTokens,
            cacheWriteTokens: decisionSnapshot.cacheWriteTokens,
            costMicros: decisionSnapshot.costMicros,
            lastInputTokens: decisionSnapshot.lastInputTokens,
            lastOutputTokens: decisionSnapshot.lastOutputTokens,
            lastRequestDurationMillis: decisionSnapshot.lastRequestDurationMillis,
            toolCalls: decisionSnapshot.toolCalls,
            turns: decisionSnapshot.turns
        )
        let pending = match (pendingCommittedToolCalls(control)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                durableRequest,
                context,
                control,
                error,
                sink,
                counter: Some(resumedCounter)
            )
        }
        if (!pending.isEmpty()) {
            match (runToolCalls(
                durableRequest,
                context,
                control,
                resumedCounter,
                pending,
                sink,
                resumedToolState
            )) {
                case Result.Err(error) => return fail(
                    durableRequest,
                    context,
                    control,
                    error,
                    sink,
                    counter: Some(resumedCounter)
                )
                case Result.Ok(Some(nextApproval)) => return Result.Ok(nextApproval)
                case Result.Ok(None) => ()
            }
        }
        if (resumedToolState.consecutiveCapabilityDenials >= 3) {
            return fail(
                durableRequest,
                context,
                control,
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "run.capability_denial_loop",
                    "agent repeatedly requested capabilities that are not granted for this run",
                    fields: [
                        ErrorField(
                            "consecutive_denials",
                            resumedToolState.consecutiveCapabilityDenials.toString()
                        ),
                        ErrorField(
                            "last_tool",
                            resumedToolState.lastCapabilityDeniedTool
                        )
                    ]
                ),
                sink,
                counter: Some(resumedCounter)
            )
        }
        continueRun(
            durableRequest,
            context,
            control,
            resumedCounter,
            sink,
            toolLoopState: Some(resumedToolState)
        )
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision
    ): Result<AgentRunOutcome> {
        decide(request, approval, decision, {_ => ()})
    }

    private func recoverCanonicalWork(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState
    ): Result<?AgentRunOutcome> {
        let recoveredDecision = match (modelDecisionRuntime.uncommittedDecision(request.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return optionalOutcome(fail(
                request, context, control, error, sink, counter: Some(counter)
            ))
        }
        match (recoveredDecision) {
            case Some(decision) =>
                let recoveredCalls = match (commitCanonicalModelDecision(
                    control, modelDecisionRuntime, decision
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return optionalOutcome(fail(
                        request, context, control, error, sink, counter: Some(counter)
                    ))
                }
                let _ = emitAttemptLifecycle(
                    context, control, decision.semanticRequestId, decision.attemptId,
                    "model.decision_committed", sink,
                    fields: [ValueField("decision_id", textValue(decision.id.value))]
                )
                match (runs.clearModelExecutionContinuation(
                    request.runId, decision.attemptId
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return optionalOutcome(fail(
                        request, context, control, error, sink, counter: Some(counter)
                    ))
                }
                if (recoveredCalls.isEmpty()) {
                    return optionalOutcome(completeRecoveredDecision(
                        request, context, control, counter, decision, sink
                    ))
                }
                match (runToolCalls(
                    request, context, control, counter, recoveredCalls, sink,
                    toolLoopState
                )) {
                    case Result.Err(error) => return optionalOutcome(fail(
                        request, context, control, error, sink, counter: Some(counter)
                    ))
                    case Result.Ok(Some(outcome)) => return Result.Ok(Some(outcome))
                    case Result.Ok(None) => ()
                }
            case None => ()
        }
        let canonicalPending = match (pendingCommittedToolCalls(control)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return optionalOutcome(fail(
                request, context, control, error, sink, counter: Some(counter)
            ))
        }
        if (!canonicalPending.isEmpty()) {
            match (runToolCalls(
                request, context, control, counter, canonicalPending, sink,
                toolLoopState
            )) {
                case Result.Err(error) => return optionalOutcome(fail(
                    request, context, control, error, sink, counter: Some(counter)
                ))
                case Result.Ok(Some(outcome)) => return Result.Ok(Some(outcome))
                case Result.Ok(None) => ()
            }
        }
        Result.Ok(None)
    }

    private func optionalOutcome(
        result: Result<AgentRunOutcome>
    ): Result<?AgentRunOutcome> {
        match (result) {
            case Result.Ok(outcome) => Result.Ok(Some(outcome))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func finishTurnWithoutTools(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        reply: ModelReply,
        turnId: TurnId,
        sink: AgentEventSink,
        drained!: Bool = false
    ): Result<?AgentRunOutcome> {
        if (control.source.token.isCancelled() || isRunCancelled(request.runId)) {
            return optionalOutcome(cancelledRun(request, context, control, sink))
        }
        let steering = match (injectSteering(request, context, sink)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return optionalOutcome(fail(
                request,
                context,
                error,
                sink
            ))
        }
        if (steering) {
            return Result.Ok(None)
        }
        let followUps = match (injectFollowUps(request, context, sink)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return optionalOutcome(fail(
                request,
                context,
                error,
                sink
            ))
        }
        if (followUps) {
            return Result.Ok(None)
        }
        let completed = RunSnapshot(
            request.runId,
            request.sessionId,
            RunState.Completed,
            sequence: context.currentSequence(),
            summary: if (drained) {
                "budget drained: " + reply.stopReason
            } else {
                reply.stopReason
            },
            modelRequests: counter.modelRequests,
            usage: counter.usage(),
            lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens,
            lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls,
            turns: counter.turns,
            structuredOutput: reply.structuredOutput
        )
        let transition = match (control.finish(
            RunState.Completed,
            reason: "run completed"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return optionalOutcome(fail(
                request,
                context,
                control,
                error,
                sink,
                counter: Some(counter)
            ))
        }
        if (transition.to != RunState.Completed) {
            return optionalOutcome(fail(request, context, control,
                AgentError(AgentErrorKind.RecoveryRequired, "run.owned_work_unsettled",
                    "owned work prevented successful Run settlement"),
                sink, counter: Some(counter)))
        }
        match (runs.save(completed)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                finishControl(request.runId)
                return Result.Err(error)
        }
        let _ = emitTyped(
            context,
            control,
            AgentEventPayload.TurnCompleted(turnId),
            sink,
            turnId: Some(turnId)
        )
        match (reply.structuredOutput) {
            case Some(value) =>
                let _ = emitTyped(
                    context,
                    control,
                    AgentEventPayload.StructuredOutputCompleted(value),
                    sink,
                    turnId: Some(turnId)
                )
            case None => ()
        }
        let _ = emitTransition(context, control, transition, sink)
        let _ = emitTyped(
            context,
            control,
            AgentEventPayload.RunCompleted,
            sink,
            turnId: Some(turnId)
        )
        finishControl(request.runId)
        Result.Ok(Some(AgentRunOutcome.Completed(completed)))
    }

    private func buildBoundedModelRequest(
        request: AgentRunRequest,
        history: Array<ModelMessage>,
        control: CoreRunControl,
        drainFinalization!: Bool = false
    ): Result<PreparedModelRequest> {
        match (validateContextSnapshotUse(request.contextSnapshot)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (model.validatePolicySnapshot(request.model, Some(request.modelCapabilitiesSnapshot))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // The drain finalization is a control-plane request: no tool surface,
        // NoTools choice, and a bounded wrap-up instruction. It must never be
        // able to start shell, edit, git, network, or any other side effect.
        var tools159 = if (drainFinalization) {
            (None<OwnedModelTools159>, Array<ModelToolDefinition>())
        } else {
            match (coreModelToolsForRequest159(control.runtime, ThreadId(request.sessionId.value))) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value
            }
        }
        let ownedTools159 = tools159[0]
        var requestTools = tools159[1]
        tools159 = (None<OwnedModelTools159>, Array<ModelToolDefinition>())
        let built = buildBoundedModelRequestFrame159(request, history, control,
            requestTools, ownedTools159, drainFinalization)
        match (built) {
            case Result.Err(_) =>
                requestTools = Array<ModelToolDefinition>()
                match (ownedTools159) {
                    case Some(owner) => owner.closeAfterPreparedFrame159(); case None => () }
            case Result.Ok(_) => ()
        }
        built
    }

    private func buildBoundedModelRequestFrame159(request: AgentRunRequest,
        history: Array<ModelMessage>, control: CoreRunControl,
        requestTools: Array<ModelToolDefinition>, ownedTools159: ?OwnedModelTools159,
        drainFinalization: Bool): Result<PreparedModelRequest> {
        let baseSystem = systemWithContextSnapshot(
            request.system,
            request.contextSnapshot
        )
        let effectiveSystem = if (drainFinalization) {
            baseSystem +
                "\n\n[BUDGET DRAINING] The work-turn budget is exhausted. Do " +
                "not investigate new problems and do not call tools. Summarize " +
                "the work already completed, the key verifications already " +
                "performed, what remains unfinished, the current blockers, and " +
                "the exact next step for a future resume. Never claim " +
                "unfinished work as complete."
        } else {
            baseSystem
        }
        let contextWindow = buildRequestContext(
            history,
            request.budget,
            system: effectiveSystem,
            tools: requestTools
        )
        if (contextWindow.overBudget) {
            return Result.Err(AgentError(
                AgentErrorKind.BudgetExceeded,
                "run.context_budget_exceeded",
                "model request context exceeds maxInputTokens",
                fields: [
                    ErrorField("estimated_input_tokens", contextWindow.estimatedTokens.toString()),
                    ErrorField("max_input_tokens", request.budget.maxInputTokens.toString())
                ]
            ))
        }
        let requestId = control.nextRequestId()
        Result.Ok(PreparedModelRequest(requestId, ModelRequest(
            request.model,
            contextWindow.messages,
            system: effectiveSystem,
            tools: requestTools,
            inputToolsLifetime159: match (ownedTools159) {
                case Some(value) => Some(value); case None => None<ModelInputToolsLifetime159>
            },
            toolChoice: if (drainFinalization) {
                ModelToolChoice.NoTools
            } else {
                ModelToolChoice.Auto
            },
            thinking: request.thinking,
            maxOutputTokens: request.budget.maxOutputTokens,
            streaming: true,
            // The host opts in only after capability negotiation. Core
            // preserves that decision and executes received calls in
            // conflict-aware waves.
            parallelToolCalls: request.parallelToolCalls,
            requestId: requestId.value,
            serviceTier: request.serviceTier,
            cachePolicy: request.cachePolicy,
            structuredOutput: request.structuredOutput,
            cacheKey: request.cacheKey
        ), contextWindow.estimatedTokens, ownedTools159: ownedTools159))
    }

    private func accountModelReply(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        reply: ModelReply,
        startedAt: MonoTime,
        turnId: TurnId,
        requestId: RequestId,
        sink: AgentEventSink
    ): Result<?AgentRunOutcome> {
        let requestDurationMillis = max(
            0,
            (MonoTime.now() - startedAt).toMilliseconds()
        )
        let observedUsage = accountedModelAttemptUsage(reply, request.pricing)
        match (counter.accountReply(
            reply,
            request.budget,
            request.pricing,
            requestDurationMillis
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = control.ledger.recordObservedUsage(observedUsage)
                return optionalOutcome(fail(
                    request,
                    context,
                    error,
                    sink,
                    counter: Some(counter)
                ))
        }
        let replyCost = match (observedUsage.costMicros) {
            case Some(value) => value
            case None => 0
        }
        match (reserveBudget(
            control,
            context,
            BudgetCharge(
                inputTokens: reply.inputTokens,
                outputTokens: reply.outputTokens,
                costMicros: replyCost
            ),
            sink,
            turnId: Some(turnId),
            requestId: Some(requestId),
            observedUsage: Some(observedUsage)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return optionalOutcome(fail(
                request,
                context,
                control,
                error,
                sink,
                counter: Some(counter)
            ))
        }
        let _ = emitTyped(
            context,
            control,
            AgentEventPayload.ModelUsageUpdated(observedUsage),
            sink,
            turnId: Some(turnId),
            requestId: Some(requestId)
        )
        Result.Ok(None)
    }

    private func commitModelDecision(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        decision: ModelDecision,
        sink: AgentEventSink
    ): Result<Array<CommittedToolCallRef>> {
        let committedToolCalls = match (commitCanonicalModelDecision(
            control,
            modelDecisionRuntime,
            decision
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let _ = emitAttemptLifecycle(
            context,
            control,
            decision.semanticRequestId,
            decision.attemptId,
            "model.decision_committed",
            sink,
            fields: [ValueField(
                "decision_id", textValue(decision.id.value)
            )]
        )
        match (runs.clearModelExecutionContinuation(
            request.runId,
            decision.attemptId
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(committedToolCalls)
    }

    private func executeCommittedTools(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        committedToolCalls: Array<CommittedToolCallRef>,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState
    ): Result<?AgentRunOutcome> {
        if (!committedToolCalls.isEmpty()) {
            match (runToolCalls(
                request,
                context,
                control,
                counter,
                committedToolCalls,
                sink,
                toolLoopState
            )) {
                case Result.Err(error) => return optionalOutcome(fail(
                    request,
                    context,
                    control,
                    error,
                    sink,
                    counter: Some(counter)
                ))
                case Result.Ok(Some(outcome)) => return Result.Ok(Some(outcome))
                case Result.Ok(None) => ()
            }
        }
        if (toolLoopState.consecutiveCapabilityDenials >= 3) {
            return optionalOutcome(fail(
                request,
                context,
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "run.capability_denial_loop",
                    "agent repeatedly requested capabilities that are not granted for this run",
                    fields: [
                        ErrorField(
                            "consecutive_denials",
                            toolLoopState.consecutiveCapabilityDenials.toString()
                        ),
                        ErrorField(
                            "last_tool",
                            toolLoopState.lastCapabilityDeniedTool
                        )
                    ]
                ),
                sink,
                counter: Some(counter)
            ))
        }
        Result.Ok(None)
    }

    private func recordPreparedActiveManifest159(prepared: PreparedModelRequest,
        request: AgentRunRequest, control: CoreRunControl, stepId: StepId,
        stepOrdinal: Int64, projection: ModelContextProjection): Result<Unit> {
        let active = control.runtime.activeRunOwned159().getOrThrow()
        let recorded = recordPreparedActiveManifestFrame159(prepared, request, active,
            stepId, stepOrdinal, projection)
        match (recorded) { case Result.Err(_) => prepared.returnPreparedFrame159(); case Result.Ok(_) => () }
        recorded
    }
    private func recordPreparedActiveManifestFrame159(prepared: PreparedModelRequest,
        request: AgentRunRequest, active: OwnedActiveRunFrame159, stepId: StepId,
        stepOrdinal: Int64, projection: ModelContextProjection): Result<Unit> {
        let loan = prepared.borrowTools159()
        match (contextManifestRuntime) {
            case actual: ReturningModelContextManifestRuntime159 =>
                actual.recordBeforeModelEffectWithOwnedLane159(loan, active, request,
                    prepared.requestId, stepId, stepOrdinal, projection,
                    modelRequestCheckpointValue(prepared.request), prepared.estimatedInputTokens, agentUtcMillis())
            case _ =>
                // The historical callback can retain lane/Strings/DOM. Keep
                // its independent active view and input loan, regardless of Unit.
                let raw = active.snapshot159()
                contextManifestRuntime.recordBeforeModelEffect(request, prepared.requestId,
                    raw.turnId, raw.executionLaneId, stepId, stepOrdinal, projection, raw.lane,
                    modelRequestCheckpointValue(prepared.request), prepared.estimatedInputTokens, agentUtcMillis())
        }
    }

    private func recordPreparedManifest159(prepared: PreparedModelRequest,
        request: AgentRunRequest, requestId: RequestId, turnId: SemanticTurnId,
        executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        let loan = prepared.borrowTools159()
        let recorded = recordPreparedManifestFrame159(loan, request, requestId, turnId,
            executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest,
            estimatedInputTokens, observedAtMillis)
        match (recorded) { case Result.Err(_) => prepared.returnPreparedFrame159(); case Result.Ok(_) => () }
        recorded
    }

    private func recordPreparedManifestFrame159(loan: ?ModelInputToolsBorrow159,
        request: AgentRunRequest, requestId: RequestId, turnId: SemanticTurnId,
        executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        match (loan) {
            case Some(input) => match (contextManifestRuntime) {
                case actual: ReturningModelContextManifestRuntime159 =>
                    actual.recordBeforeModelEffectReturning159(input, request, requestId, turnId, executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis)
                case _ => contextManifestRuntime.recordBeforeModelEffect(request, requestId, turnId, executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis)
            }
            case None => contextManifestRuntime.recordBeforeModelEffect(request, requestId, turnId, executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis)
        }
    }

    private func executeCanonicalModelTurn(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        prepared: PreparedModelRequest,
        turnId: TurnId,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState
    ): Result<CoreTurnExecution> {
        try {
            executeCanonicalModelTurnFrame159(request, context, control, counter,
                prepared, turnId, sink, toolLoopState)
        } catch (failure: IllegalStateException) {
            Result.Err(AgentError(AgentErrorKind.Internal, "run.result_observer_exception", failure.message))
        } finally { prepared.returnPreparedFrame159() }
    }

    private func executeCanonicalModelTurnFrame159(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        prepared: PreparedModelRequest,
        turnId: TurnId,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState
    ): Result<CoreTurnExecution> {
        let modelRequestStartedAt = MonoTime.now()
        let requestId = prepared.requestId
        match (emitTyped(
            context,
            control,
            AgentEventPayload.AssistantStarted(requestId),
            sink,
            turnId: Some(turnId),
            requestId: Some(requestId)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return turnExecution(fail(
                request,
                context,
                control,
                error,
                sink,
                counter: Some(counter)
            ))
        }
        let durableResult = match (executeModelWithTurnRetry(
            request,
            counter,
            prepared.request,
            context,
            control,
            sink,
            toolLoopState
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return if (
                error.kind == AgentErrorKind.RecoveryRequired
            ) {
                Result.Err(error)
            } else {
                turnExecution(fail(
                    request,
                    context,
                    error,
                    sink,
                    counter: Some(counter)
                ))
            }
        }
        let reply = durableResult.reply
        if (control.source.token.isCancelled() || isRunCancelled(request.runId)) {
            return turnExecution(cancelledRun(
                request,
                context,
                control,
                sink,
                counter: Some(counter)
            ))
        }
        match (accountModelReply(
            request,
            context,
            control,
            counter,
            reply,
            modelRequestStartedAt,
            turnId,
            requestId,
            sink
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(outcome)) => return Result.Ok(
                CoreTurnExecution.Finished(outcome)
            )
            case Result.Ok(None) => ()
        }
        let committedToolCalls = match (commitModelDecision(
            request,
            context,
            control,
            durableResult.decision,
            sink
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return turnExecution(fail(
                request,
                context,
                control,
                error,
                sink,
                counter: Some(counter)
            ))
        }
        let calledTool = !committedToolCalls.isEmpty()
        match (executeCommittedTools(
            request,
            context,
            control,
            counter,
            committedToolCalls,
            sink,
            toolLoopState
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(outcome)) => return Result.Ok(
                CoreTurnExecution.Finished(outcome)
            )
            case Result.Ok(None) => ()
        }
        Result.Ok(CoreTurnExecution.ReadyToFinish(reply, calledTool))
    }

    private func turnExecution(
        result: Result<AgentRunOutcome>
    ): Result<CoreTurnExecution> {
        match (result) {
            case Result.Ok(outcome) => Result.Ok(CoreTurnExecution.Finished(outcome))
            case Result.Err(error) => Result.Err(error)
        }
    }

    // Trusted in-process preparation. The request carries no filesystem grant;
    // the actual Run's canonical read policy, ledger and approval still apply.
    public func queueContextReadUpdate(run: RunId, epoch: Int64, previousDigest: String,
        read: ToolPreparationRead, validity!: () -> Result<Unit> = { => Result.Ok(()) },
        sequence!: ?ContextReadSequence = None, requiredBeforeModel!: Bool = false): Result<ContextReadUpdate> {
        let control = match (controls.find(run)) { case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.Conflict,
                "context.update_stale", "context read requires its actual active Core owner")) }
        let active = match (control.runtime.activeRunControl159()) { case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.Conflict,
                "context.update_stale", "context read requires its actual active Run")) }
        if (active[2].value != run.value || active[3] != epoch ||
            contextReadProjectionDigest(active[5]) != previousDigest || control.source.token.isCancelled()) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.update_stale", "context read lost its expected Run or projection")) }
        let ticket = ContextReadUpdate(control.runtime, run, epoch, previousDigest, read, validity,
            { operation, actualRun => operationRuntime.loadContextReadFact(operation, actualRun) }, sequence: sequence,
            requiredBeforeModel: requiredBeforeModel)
        match (control.retainContextUpdate(ticket)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ticket)
    }

    private func prepareContextUpdate(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: BudgetCounter, sink: AgentEventSink): Result<?AgentRunOutcome> {
        if (!control.atModelLaneSafeCut()) { return Result.Ok(None) }
        let update = match (control.peekContextUpdate()) { case Some(value) => value; case None => return Result.Ok(None) }
        // Keep the same host continuation owned through every read approval.
        // No model request may interleave between metadata and selected body.
        while (update.state() == ContextReadUpdateState.Queued) {
            if (!update.claim()) { break }
            let readRequestId = match (control.nextContextReadRequestId()) {
                case Result.Ok(value) => value
                case Result.Err(error) => update.deny(error.code); control.releaseContextUpdate(update); return Result.Err(error)
            }
            match (executePreparationRead(request, context, control, counter, update.owner(),
                readRequestId, None, sink)) {
                case Result.Err(error) =>
                    update.deny(error.code); control.releaseContextUpdate(update); return Result.Err(error)
                case Result.Ok(Some(value)) => return Result.Ok(Some(value))
                case Result.Ok(None) => ()
            }
        }
        let state = update.state()
        if (state != ContextReadUpdateState.Reading && !(update.requiredBeforeModel && state == ContextReadUpdateState.ReadyAtCut)) {
            control.releaseContextUpdate(update) }
        if (update.requiredBeforeModel && state == ContextReadUpdateState.Discarded) {
            return Result.Err(AgentError(if (context.cancellation.isCancelled()) { AgentErrorKind.Cancelled } else { AgentErrorKind.Conflict },
                if (update.diagnostic() == "") { "context.initial_preparation_failed" } else { update.diagnostic() },
                "required initial context did not complete its canonical read and context cut")) }
        if (state == ContextReadUpdateState.Reading) { return Result.Err(AgentError(AgentErrorKind.Conflict,
            "context.read_owner_pending", "a retained context read owner must settle before another model request")) }
        Result.Ok(None)
    }

    private func refreshToolSetAtSafeCut(
        request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, counter: BudgetCounter, state: CoreToolLoopState
    ): Result<ToolInvocationContext> {
        if (context.cancellation.isCancelled() || !control.atModelLaneSafeCut()) {
            return Result.Ok(context)
        }
        let boundary: () -> AgentValue = { => coreContextBoundaryCapture(requestWithContextSnapshot(request, context.contextProjection), counter, control, state) }
        let contextActive = match (control.runtime.applyContextSnapshotAtSafeCut(request.runId, context.epoch, coreBoundary: Some(boundary))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let preparedContext159 = applyContextCutView159(request, context, control, sink, contextActive)
        // Only this private complete consumer returned. The resulting Context
        // either is the input or owns its separate forked snapshot handle.
        contextActive.returnOwnedLaneView159()
        let contextView = match (preparedContext159) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let active = match (control.runtime.activeRunOwned159()) {
            case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "run.model_lane_cut_conflict", "Run is not active"))
        }
        let result = refreshCatalogCutView159(request, contextView, control, sink, counter, state, active.snapshot159())
        active.returnActiveRunFrame159()
        result
    }

    private func applyContextCutView159(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, contextActive: ActiveRunSnapshot): Result<ToolInvocationContext> {
        // Runtime intentionally discards optional stale updates without an
        // error. A required initial ticket must survive until this actual CAS.
        match (control.peekContextUpdate()) {
            case Some(update) => if (update.requiredBeforeModel) {
                let state = update.state()
                if (state != ContextReadUpdateState.Applied) {
                    update.deny(if (update.diagnostic() == "") { "context.initial_cut_uncommitted" } else { update.diagnostic() })
                    control.releaseContextUpdate(update)
                    return Result.Err(AgentError(AgentErrorKind.Conflict, update.diagnostic(),
                        "required initial context was withdrawn or not committed at its actual safe cut")) }
                control.releaseContextUpdate(update)
            }
            case None => ()
        }
        let contextView = if (contextReadProjectionDigest(context.contextProjection) ==
            contextReadProjectionDigest(contextActive.contextSnapshot)) { context }
            else { context.withContextSnapshot(contextActive.contextSnapshot) }
        if (!refEq(contextView, context)) { bindBudgetChargeHandler(contextView, control, sink) }
        Result.Ok(contextView)
    }

    private func refreshCatalogCutView159(request: AgentRunRequest, contextView: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, counter: BudgetCounter, state: CoreToolLoopState,
        active: ActiveRunSnapshot): Result<ToolInvocationContext> {
        if (coreCatalogMatchesLane159(catalog, active.lane, request.capabilities, ThreadId(request.sessionId.value))) {
            return Result.Ok(contextView)
        }
        match (active.lane.forkOwnedToolSetSnapshot159()) {
            case Some(expected) =>
                try { return refreshOwnedCatalogCutView159(request, contextView, control, sink, counter, state, active, expected) }
                finally { expected.close159() }
            case None => ()
        }
        // A changed catalog still takes the original durable CAS route below.
        // Its raw cut DTO remains charged until that separate owner is migrated.
        let observed = match (catalog.changedToolSetSnapshot159(active.lane.toolSet, "catalog-observed",
            request.capabilities, threadId: Some(ThreadId(request.sessionId.value)))) {
            case Some(value) => value
            case None => return Result.Ok(contextView)
        }
        let digest = toolSetSnapshotContentDigest(observed)
        let replacement = ToolSetSnapshot("catalog-" + request.runId.value + "-" + digest,
            observed.entries, hookHandlers: observed.hookHandlers, threadId: observed.threadId)
        let updated = match (control.runtime.replaceToolSetAtSafeCut(request.runId,
            contextView.epoch, active.lane, replacement, coreBoundary: Some(coreContextBoundaryCapture(
                requestWithContextSnapshot(request, contextView.contextProjection), counter, control, state)))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let result = bindUpdatedCatalogCutView159(contextView, control, sink, updated)
        updated.returnOwnedLaneView159()
        result
    }

    private func refreshOwnedCatalogCutView159(request: AgentRunRequest, contextView: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, counter: BudgetCounter, state: CoreToolLoopState,
        active: ActiveRunSnapshot, expected: SharedToolSetSnapshot159): Result<ToolInvocationContext> {
        let replacement = match (catalog.changedSharedToolSetSnapshot159(expected, request.runId,
            request.capabilities, threadId: Some(ThreadId(request.sessionId.value)))) {
            case Some(value) => value
            case None => return Result.Ok(contextView)
        }
        try { refreshOwnedCatalogCutFrame159(request, contextView, control, sink, counter, state, active, replacement) }
        finally { replacement.close159() }
    }
    private func refreshOwnedCatalogCutFrame159(request: AgentRunRequest, contextView: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, counter: BudgetCounter, state: CoreToolLoopState,
        active: ActiveRunSnapshot, replacement: SharedToolSetSnapshot159): Result<ToolInvocationContext> {
        let updated = match (control.runtime.replaceOwnedToolSetAtSafeCut159(request.runId,
            contextView.epoch, active.lane, replacement, coreBoundary: Some(coreContextBoundaryCapture(
                requestWithContextSnapshot(request, contextView.contextProjection), counter, control, state)))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let result = bindUpdatedCatalogCutView159(contextView, control, sink, updated)
        updated.returnOwnedLaneView159()
        result
    }

    private func bindUpdatedCatalogCutView159(contextView: ToolInvocationContext,
        control: CoreRunControl, sink: AgentEventSink, updated: ActiveRunSnapshot): Result<ToolInvocationContext> {
        let view = match (updated.lane.forkOwnedToolSetSnapshot159()) {
            case Some(value) => contextView.withOwnedToolSetSnapshot159(value)
            case None => contextView.withToolSetSnapshot(updated.lane.legacyToolSetSnapshot159().getOrThrow())
        }
        bindBudgetChargeHandler(view, control, sink)
        Result.Ok(view)
    }

    private func continueRun(
        initialRequest: AgentRunRequest,
        initialContext: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        sink: AgentEventSink,
        toolLoopState!: ?CoreToolLoopState = None,
        resumedPaidTurn!: Bool = false
    ): Result<AgentRunOutcome> {
        let request = initialRequest
        let activeToolLoopState = match (toolLoopState) {
            case Some(value) => value
            case None => CoreToolLoopState()
        }
        match (recoverCanonicalWork(
            request,
            initialContext,
            control,
            counter,
            sink,
            activeToolLoopState
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(outcome)) => return Result.Ok(outcome)
            case Result.Ok(None) => ()
        }
        var nextContext = initialContext
        var resumePaidTurn = resumedPaidTurn
        let pressureAtTurns = budgetPressureAtTurns(request.budget.maxTurns)
        while (counter.turns < request.budget.maxTurns || resumePaidTurn) {
            if (!resumePaidTurn) { match (prepareContextUpdate(requestWithContextSnapshot(initialRequest, nextContext.contextProjection),
                nextContext, control, counter, sink)) {
                case Result.Err(error) => return fail(request, nextContext, control, error, sink, counter: Some(counter))
                case Result.Ok(Some(value)) => return Result.Ok(value)
                case Result.Ok(None) => ()
            }
            }
            // A previously charged turn uses its frozen current context. No new
            // cut may replace turn_reserved with after_safe_cut before prepare.
            let context = if (resumePaidTurn) { nextContext } else { match (refreshToolSetAtSafeCut(request, nextContext, control, sink, counter, activeToolLoopState)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(request, nextContext, control, error, sink,
                    counter: Some(counter))
            } }
            nextContext = context
            let currentRequest = requestWithContextSnapshot(initialRequest, context.contextProjection)
            if (control.source.token.isCancelled() || isRunCancelled(currentRequest.runId)) {
                return cancelledRun(
                    currentRequest,
                    context,
                    control,
                    sink,
                    counter: Some(counter)
                )
            }
            let alreadyReserved = resumePaidTurn
            let turnId = if (alreadyReserved) { control.currentTurnId().getOrThrow() } else {
                match (reserveContextBoundaryTurn(currentRequest, context, control, counter, activeToolLoopState, sink)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return fail(currentRequest, context, control, error, sink, counter: Some(counter)) }
            }
            resumePaidTurn = false
            // Only actual still-pending inputs are returned by the live interaction
            // source. Already consumed canonical tickets are never reconstructed.
            match (injectSteering(currentRequest, context, sink)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return fail(currentRequest, context, error, sink, counter: Some(counter)) }
            if (!alreadyReserved) { counter.turns += 1 }
            let pressureAlreadyCommitted = if (alreadyReserved && counter.turns == pressureAtTurns) {
                match (runs.contextBoundaryPressureItem(currentRequest.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error) }
            } else { false }
            if (counter.turns == pressureAtTurns && control.enterPressure() && !pressureAlreadyCommitted) {
                let _ = emitTyped(
                    context,
                    control,
                    AgentEventPayload.BudgetSignal(BudgetSignalSnapshot(
                        BudgetMode.Pressure,
                        BudgetDimension.Turns,
                        currentRequest.budget.maxTurns,
                        counter.turns,
                        currentRequest.budget.maxTurns - counter.turns
                    )),
                    sink
                )
                match (announceBudgetPressure(currentRequest, context, control, sink)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return fail(
                        currentRequest, context, control, error, sink,
                        counter: Some(counter)
                    )
                }
            }
            let projection = match (control.runtime.projectContext()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(
                    currentRequest,
                    context,
                    error,
                    sink
                )
            }
            let continuationInputs = match (continuationProjectionInputs(projection, runs)) {
                case Result.Err(error) => return fail(currentRequest, context, control, error, sink)
                case Result.Ok(value) => value }
            let history = modelMessagesFromProjectionWithContinuation(projection, continuationInputs)
            let preparedModelRequest = match (buildBoundedModelRequest(
                currentRequest,
                history,
                control
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(
                    currentRequest,
                    context,
                    error,
                    sink,
                    counter: Some(counter)
                )
            }
            match (recordPreparedActiveManifest159(preparedModelRequest,
                currentRequest, control, StepId(
                    "step-" + currentRequest.runId.value + "-" +
                        (counter.turns - 1).toString()
                ), counter.turns - 1, projection)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return fail(
                    currentRequest,
                    context,
                    control,
                    error,
                    sink,
                    counter: Some(counter)
                )
            }
            let (reply, calledTool) = match (executeCanonicalModelTurn(
                currentRequest,
                context,
                control,
                counter,
                preparedModelRequest,
                turnId,
                sink,
                activeToolLoopState
            )) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(CoreTurnExecution.Finished(outcome)) =>
                    return Result.Ok(outcome)
                case Result.Ok(CoreTurnExecution.ReadyToFinish(value, called)) =>
                    (value, called)
            }
            if (!calledTool) {
                match (finishTurnWithoutTools(
                    currentRequest,
                    context,
                    control,
                    counter,
                    reply,
                    turnId,
                    sink
                )) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(Some(outcome)) => return Result.Ok(outcome)
                    case Result.Ok(None) => continue
                }
            }
            let _ = emitTyped(
                context,
                control,
                AgentEventPayload.TurnCompleted(turnId),
                sink,
                turnId: Some(turnId)
            )
        }
        let context = nextContext
        // The work-turn budget is exhausted at a settlement boundary. Do not
        // start another work turn and never surface budget.turns_exceeded for
        // this normal path: enter the bounded control-plane drain, checkpoint
        // durably, and let the model deliver a no-tools partial/final report.
        drainRun(requestWithContextSnapshot(initialRequest, context.contextProjection), context, control, counter, sink)
    }

    // Derived pressure threshold: fire once when warningLeadTurns or fewer
    // work turns remain. Derived, not configured, in v1.
    private func budgetPressureAtTurns(maxTurns: Int64): Int64 {
        let leadRaw = maxTurns / 8
        let leadTurns = if (leadRaw < 1) {
            1
        } else if (leadRaw > 4) {
            4
        } else {
            leadRaw
        }
        let threshold = maxTurns - leadTurns
        if (threshold < 1) {
            1
        } else {
            threshold
        }
    }

    // One durable user-visible notice at the pressure crossing: it rides the
    // thread projection into later model requests without per-turn prompt
    // rewrites.
    private func announceBudgetPressure(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        match (control.runtime.appendUserInput(
            ItemId("budget-pressure-" + request.runId.value),
            ThreadItemContent.UserMessage(textMessageParts(
                "[budget pressure] The work-turn budget is nearly exhausted. " +
                    "Finish the current goal now, avoid starting optional " +
                    "exploration, and converge the current work into a " +
                    "deliverable state."
            )),
            ItemProvenance("budget", runId: Some(request.runId)),
            agentUtcMillis()
        )) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func saveDrainCheckpoint(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        counter: BudgetCounter
    ): Result<Unit> {
        runs.save(RunSnapshot(
            request.runId,
            request.sessionId,
            RunState.Running,
            sequence: context.currentSequence(),
            summary: "work turn budget reached; draining",
            modelRequests: counter.modelRequests,
            usage: counter.usage(),
            lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens,
            lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls,
            turns: counter.turns
        ))
    }

    // Deadline- or crash-style drain ending: no further provider request is
    // admitted, the durable checkpoint is the delivered partial result.
    private func completeDrainedRun(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        sink: AgentEventSink,
        summary: String
    ): Result<AgentRunOutcome> {
        let completed = RunSnapshot(
            request.runId,
            request.sessionId,
            RunState.Completed,
            sequence: context.currentSequence(),
            summary: summary,
            modelRequests: counter.modelRequests,
            usage: counter.usage(),
            lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens,
            lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls,
            turns: counter.turns
        )
        let transition = match (control.finish(
            RunState.Completed,
            reason: summary
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return fail(
                request, context, control, error, sink, counter: Some(counter)
            )
        }
        if (transition.to != RunState.Completed) {
            return fail(request, context, control,
                AgentError(AgentErrorKind.RecoveryRequired, "run.owned_work_unsettled",
                    "owned work prevented successful Run settlement"),
                sink, counter: Some(counter))
        }
        match (runs.save(completed)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                finishControl(request.runId)
                return Result.Err(error)
        }
        let _ = emitTransition(context, control, transition, sink)
        let _ = emitTyped(context, control, AgentEventPayload.RunCompleted, sink)
        finishControl(request.runId)
        Result.Ok(AgentRunOutcome.Completed(completed))
    }

    // Bounded control-plane drain after the work-turn budget is exhausted.
    // Durable checkpoint first, then at most maxDrainTurns no-tools
    // finalization requests; hard dimensions (deadline) are never extended.
    private func drainRun(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        if (control.beginDraining()) {
            let _ = emitTyped(
                context,
                control,
                AgentEventPayload.BudgetSignal(BudgetSignalSnapshot(
                    BudgetMode.Draining,
                    BudgetDimension.Turns,
                    request.budget.maxTurns,
                    counter.turns,
                    0
                )),
                sink
            )
        }
        match (saveDrainCheckpoint(request, context, counter)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return fail(
                request, context, control, error, sink, counter: Some(counter)
            )
        }
        while (true) {
            if (control.drainAttempts() >= request.budget.maxDrainTurns) {
                return fail(
                    request, context, control,
                    AgentError(
                        AgentErrorKind.BudgetExceeded,
                        "budget.drain_exhausted",
                        "drain turn budget exhausted before finalization completed"
                    ),
                    sink,
                    counter: Some(counter)
                )
            }
            let _ = control.incrementDrainAttempts()
            let projection = match (control.runtime.projectContext()) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(
                    request, context, control, error, sink, counter: Some(counter)
                )
            }
            let continuationInputs = match (continuationProjectionInputs(projection, runs)) {
                case Result.Err(error) => return fail(request, context, control, error, sink)
                case Result.Ok(value) => value }
            let history = modelMessagesFromProjectionWithContinuation(projection, continuationInputs)
            let preparedModelRequest = match (buildBoundedModelRequest(
                request, history, control, drainFinalization: true
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(
                    request, context, control, error, sink, counter: Some(counter)
                )
            }
            match (model.validatePolicySnapshot(request.model, Some(request.modelCapabilitiesSnapshot))) {
                case Result.Err(error) => return fail(request, context, control, error, sink, counter: Some(counter))
                case Result.Ok(_) => () }
            let effectiveDrainRequest = match (resolvedModelRequestForAttempt(
                request, preparedModelRequest.request
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return fail(
                    request, context, control, error, sink, counter: Some(counter)
                )
            }
            // Conservative projection-based admission before provider
            // dispatch, not an absolute physical guarantee: worst case =
            // request-window input estimate at the input rate (no cache
            // discount) plus the per-request wire output hard limit at the
            // output rate, priced through the same priceModelUsage rounding
            // as accounting. If the projection does not fit the remaining
            // cumulative budget, no request is sent and the durable
            // checkpoint is the delivered partial result. Actual replies are
            // still accounted ex-post; input estimate drift and unobservable
            // provider consumption from failed transports are outside strict
            // preflight scope.
            let worstCaseUsage = ExecutionUsage(
                inputTokens: preparedModelRequest.estimatedInputTokens,
                outputTokens: effectiveDrainRequest.wireMaxOutputTokens,
                costMicros: match (request.pricing) {
                    case Some(pricing) =>
                        match (priceModelUsage(ModelUsage(
                            inputTokens: preparedModelRequest.estimatedInputTokens,
                            outputTokens: effectiveDrainRequest.wireMaxOutputTokens
                        ), pricing)) {
                            case Some(value) => value
                            case None => 0
                        }
                    case None => 0
                }
            )
            let blocked = control.ledger.projectedAdmissionBlocked(worstCaseUsage)
            if (blocked.isSome()) {
                let enteredExhausted = control.markExhausted()
                let usageNow = control.ledger.snapshot()
                let dimension = blocked.getOrThrow()
                let (limitValue, usedValue): (Int64, Int64) = match (dimension) {
                    case BudgetDimension.Deadline =>
                        (request.budget.deadlineMillis, request.budget.deadlineMillis)
                    case BudgetDimension.InputTokens =>
                        (request.budget.maxTotalInputTokens, usageNow.inputTokens)
                    case BudgetDimension.OutputTokens =>
                        (request.budget.maxTotalOutputTokens, usageNow.outputTokens)
                    case _ =>
                        (request.budget.maxCostMicros, usageNow.costMicros)
                }
                if (enteredExhausted) {
                    let _ = emitTyped(
                        context,
                        control,
                        AgentEventPayload.BudgetSignal(BudgetSignalSnapshot(
                            BudgetMode.Exhausted,
                            dimension,
                            limitValue,
                            usedValue,
                            0
                        )),
                        sink
                    )
                }
                return completeDrainedRun(
                    request, context, control, counter, sink,
                    "run drained at hard budget limit without finalization request"
                )
            }
            let turnId = control.nextTurnId()
            match (recordPreparedActiveManifest159(preparedModelRequest,
                request, control, StepId(
                    "step-" + request.runId.value + "-drain-" +
                        control.drainAttempts().toString()
                ), counter.turns, projection)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return fail(
                    request, context, control, error, sink, counter: Some(counter)
                )
            }
            let (reply, calledTool) = match (executeCanonicalModelTurn(
                request, context, control, counter, preparedModelRequest,
                turnId, sink, CoreToolLoopState()
            )) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(CoreTurnExecution.Finished(outcome)) =>
                    return Result.Ok(outcome)
                case Result.Ok(CoreTurnExecution.ReadyToFinish(value, called)) =>
                    (value, called)
            }
            if (calledTool) {
                return fail(
                    request, context, control,
                    AgentError(
                        AgentErrorKind.BudgetExceeded,
                        "budget.drain_exhausted",
                        "drain finalization returned tool calls; refusing new tool work"
                    ),
                    sink,
                    counter: Some(counter)
                )
            }
            match (finishTurnWithoutTools(
                request, context, control, counter, reply, turnId, sink,
                drained: true
            )) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(Some(outcome)) => return Result.Ok(outcome)
                case Result.Ok(None) => ()
            }
        }
        // Unreachable: every loop branch returns. Kept as the typed terminal
        // expression the compiler requires for a non-Unit function.
        fail(
            request, context, control,
            AgentError(
                AgentErrorKind.BudgetExceeded,
                "budget.drain_exhausted",
                "drain loop exited without a terminal outcome"
            ),
            sink,
            counter: Some(counter)
        )
    }

    private func runToolCalls(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        calls: Array<CommittedToolCallRef>,
        sink: AgentEventSink,
        loopState: CoreToolLoopState
    ): Result<?AgentRunOutcome> {
        // Graceful drain forbids new tool side effects: a provider that
        // returns tool calls without an advertised tool surface, or a
        // recovered decision that lands while the run is draining, is a drain
        // violation and must not execute.
        if (control.budgetMode() == BudgetMode.Draining && !calls.isEmpty()) {
            return Result.Err(AgentError(
                AgentErrorKind.BudgetExceeded,
                "budget.drain_exhausted",
                "tool work is not permitted while the run is draining"
            ))
        }
        if (!interruptsImmediately(request)) {
            return runToolBatch(
                request,
                context,
                control,
                counter,
                calls,
                sink,
                loopState
            )
        }
        for (index in 0..calls.size) {
            match (runToolBatch(
                request,
                context,
                control,
                counter,
                [calls[index]],
                sink,
                loopState
            )) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(Some(outcome)) => return Result.Ok(Some(outcome))
                case Result.Ok(None) => ()
            }
            let denialLoop = loopState.consecutiveCapabilityDenials >= 3
            if (denialLoop || hasSteering(request)) {
                for (remaining in (index + 1)..calls.size) {
                    match (appendSkippedToolCall(
                        request.sessionId,
                        context,
                        control,
                        calls[remaining],
                        sink,
                        errorCode: if (denialLoop) {
                            "tool.skipped_after_capability_denial_loop"
                        } else {
                            "tool.skipped_for_steering"
                        },
                        message: if (denialLoop) {
                            "tool was skipped after repeated capability denials"
                        } else {
                            "tool was skipped because a steering message is pending"
                        }
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
                }
                return Result.Ok(None)
            }
        }
        Result.Ok(None)
    }

    // Runs before ordinary batch preparation. Hook output is frozen once; the
    // original call has not consumed its tool-call charge or become an
    // Operation yet. Each internal read has its own same-ledger charge/slot.
    private func prepareToolReadInputs(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: BudgetCounter, calls: Array<CommittedToolCallRef>,
        sink: AgentEventSink): Result<?AgentRunOutcome> {
        for (committed in calls) {
            let call = ToolCall(committed.block.callId, committed.block.name, committed.block.arguments)
            var owner = control.preparationInput(committed.canonicalItemId)
            if (owner.isNone()) {
                if (!tools.hasPreparationRead(context, call)) { continue }
                let hook = try { toolHooks.beforeTool(context, committed, call.arguments) }
                    catch (_: Exception) { CoreToolHookDecision.Deny("PreToolUse handler failed; tool call denied") }
                let input = match (hook) { case CoreToolHookDecision.Modify(value) => value; case _ => call.arguments }
                match(tools.retainPreparationInput340(context,Some(OperationRootSource.Committed(committed)),
                    ToolCall(call.callId,call.name,input),[])){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let state = try { CorePreparationReadInput(committed, input,
                    {operation,run=>operationRuntime.loadContextReadFact(operation,run)},
                    rejection: match (hook) { case CoreToolHookDecision.Deny(reason) => Some(reason); case _ => None }) }
                    catch (_: Exception) { return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                        "context.read_input_limit", "hook input cannot be frozen for preparation")) }
                match (control.retainPreparationInput(state)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                owner = Some(state)
                if (!state.ready) {
                    match (tools.preparationReadCommitted340(context, committed, ToolCall(call.callId, call.name, state.input()))) {
                        case Result.Err(error) => state.deny(error.code)
                        case Result.Ok(None) => state.ready = true
                        case Result.Ok(Some(value)) => state.beginRead(value)
                    }
                }
            }
            let state = owner.getOrThrow()
            if (state.ready) { continue }
            while(!state.ready){
                if(context.cancellation.isCancelled() || control.source.token.isCancelled()){
                    return Result.Err(controlCancellationError(control))}
                let ordinal=state.readOrdinal()
                let requestId="context-read-"+modelPolicySha256Text(committed.canonicalItemId.value)+
                    if(ordinal==0){""}else{"-"+ordinal.toString()}
                match (executePreparationRead(request, context, control, counter, state,requestId,
                    Some(OperationRootSource.Committed(committed)), sink)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(Some(value)) => return Result.Ok(Some(value))
                    case Result.Ok(None) => ()
                }
            }
        }
        Result.Ok(None)
    }

    private func executePreparationRead(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: BudgetCounter, state: CoreContextReadOwner,
        requestId: String, parent: ?OperationRootSource, sink: AgentEventSink): Result<?AgentRunOutcome> {
        let read = state.readPreparation()
        let readCall = ToolCall(requestId, HOST_CONTEXT_READ_TOOL, read.request())
        let admission = match (control.runtime.beginContextRead(readCall, read.ownerNamespace, read.packageDigest,
            read.configurationDigest, requestId, context.runId, context.epoch,
            contextReadProjectionDigest(context.contextProjection), parent: parent)) {
            case Result.Ok(value) => value; case Result.Err(error) => state.deny(error.code); return Result.Ok(None) }
        let preparation = match (tools.prepareContextRead(context, readCall, admission, read: Some(read))) {
            case Result.Ok(value) => value; case Result.Err(error) => state.deny(error.code); return Result.Ok(None) }
        var prepared = match (preparation) {
            case ToolPreparation.Ready(value) => value
            case ToolPreparation.NeedsApproval(value, _) => value
            case ToolPreparation.Denied(value) => state.deny(value.reason.code); return Result.Ok(None)
            case ToolPreparation.Completed(_) => state.deny("context.read_preparation_failed"); return Result.Ok(None)
        }
        // Record ownership before telemetry: an event-store failure after
        // a successful charge must still release the acquired slot.
        let reserved = match (control.reserve(BudgetCharge(toolCalls: 1, toolsStarted: 1))) {
            case Result.Err(error) => state.deny(error.code); return Result.Ok(None)
            case Result.Ok(value) => counter.toolCalls += 1; value
        }
        match (control.registerScheduledToolSlot(prepared.operationId, HOST_CONTEXT_READ_TOOL)) {
            case Result.Err(error) =>
                match (control.ledger.releaseTools()) { case Result.Ok(usage) =>
                    let _ = emitTyped(context, control, AgentEventPayload.BudgetUpdated(usage), sink)
                    case Result.Err(_) => () }
                return Result.Err(error)
            case Result.Ok(_) => ()
        }
        var retained = false
        try {
            match (emitTyped(context, control, AgentEventPayload.BudgetUpdated(reserved), sink,
                toolCallId: Some(ToolCallId(requestId)))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let source = match (control.runtime.commitContextReadToolCall(admission,
                ItemId("context-read-item-" + prepared.operationId.value), prepared.operationId,
                ToolCall(readCall.callId, readCall.name, prepared.operationPlan.canonicalArguments), prepared.operationPlan,
                createdAtMillis: agentUtcMillis())) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            match (operationRuntime.prepareDirectOperation(source, prepared.operationPlan)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            prepared = match (tools.bindDirectRoot(context, prepared, source)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            match (preparation) {
                case ToolPreparation.NeedsApproval(_, approval) =>
                    match (operationRuntime.waitForApproval(prepared.operationId, context.runId)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let pending = CorePendingContextRead(state, prepared, context.epoch)
                    match (control.retainPendingRead(pending)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    retained = true
                    let paused = pauseContextRead(request, context, control, counter, approval, sink)
                    match (paused) {
                        case Result.Ok(_) => return paused
                        case Result.Err(error) =>
                            // This setup failed before any executor handoff.
                            // Restore the actual state only to commit the
                            // known failure, not to approve or run the read.
                            if (control.state() == RunState.WaitingApproval) {
                                match (control.resumeAfterApproval()) {
                                    case Result.Err(_) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                                        "context.read_pause_unsettled", "read approval setup retained an unresolved canonical owner"))
                                    case Result.Ok(_) => ()
                                }
                            }
                            match (settleContextRead(context, control, state, prepared,
                                Result<ToolInvocationResult>.Err(error), false)) {
                                case Result.Err(_) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                                    "context.read_pause_unsettled", "failed read approval could not commit its terminal result"))
                                case Result.Ok(_) => ()
                            }
                            control.releasePendingRead(prepared.operationId); retained = false
                            return Result.Err(error)
                    }
                case _ => ()
            }
            let handoff = CoreExecutionHandoffState()
            let outcome = try { tools.executePrepared(context, prepared,
                { _ => handoff.started = true; Result.Ok(()) }) }
                catch (_: Exception) { Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Internal,
                    "context.read_executor_failed", "context read executor failed without a verified terminal result")) }
            match (settleContextRead(context, control, state, prepared, outcome, handoff.started)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        } finally {
            if (!retained) { let _ = releaseContextReadSlot(context, control, prepared.operationId, sink) }
        }
        Result.Ok(None)
    }

    // A preparation continuation can fail after its read succeeded but before
    // the original call starts. Preserve every original canonical terminal;
    // partial Store preparation is settled only as Prepared/no-handoff, which
    // Store independently verifies. A missing row is not an executed effect.
    private func settleReadPreparationParents(context: ToolInvocationContext, control: CoreRunControl,
        calls: Array<CommittedToolCallRef>, error: AgentError, sink: AgentEventSink,
        preparation!: ?CoreToolBatchPreparation = None): Result<Unit> {
        for (committed in calls) {
            var operation = OperationId("operation-" + committed.decisionId.value + "-" + committed.scopedToolCallId.value)
            match (preparation) {
                case Some(batch) =>
                    for (item in batch.immediate where item.committed.canonicalItemId.value == committed.canonicalItemId.value) {
                        operation = match (item.operationId) { case Some(value) => value
                            case None => OperationId("operation-immediate-" + committed.decisionId.value + "-" + committed.scopedToolCallId.value) }
                    }
                case None => ()
            }
            let settled = match (operationRuntime.loadPlan(operation, context.runId)) {
                case Result.Ok(plan) => commitCanonicalToolAttempt(control, CoreToolOutcome(0, committed,
                    Result<ToolInvocationResult>.Err(error), operationId: Some(operation), operationPlan: Some(plan),
                    attemptStage: OperationAttemptStage.Prepared))
                case Result.Err(loadError) => if (loadError.code == "operation.not_found") {
                    appendSkippedToolCall(context.sessionId, context, control, committed, sink,
                        errorCode: error.code, message: "preparation continuation failed before this original tool started")
                } else { Result<Unit>.Err(loadError) }
            }
            match (settled) {
                case Result.Err(failure) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "context.read_parent_unsettled", "canonical preparation parent remains unsettled: " + failure.code))
                case Result.Ok(_) => control.releasePreparationInput(committed.canonicalItemId)
            }
        }
        Result.Ok(())
    }

    private func hasReadPreparation(control: CoreRunControl, calls: Array<CommittedToolCallRef>): Bool {
        for (call in calls where control.preparationInput(call.canonicalItemId).isSome()) { return true }
        false
    }

    private func releaseContextReadSlot(context: ToolInvocationContext, control: CoreRunControl,
        operation: OperationId, sink: AgentEventSink): Result<Unit> {
        if (!control.unregisterScheduledToolSlot(operation)) { return Result.Ok(()) }
        match (control.ledger.releaseTools()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(usage) => emitTyped(context, control, AgentEventPayload.BudgetUpdated(usage), sink)
        }
    }

    private func pauseContextRead(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: BudgetCounter, approval: ApprovalRequest,
        sink: AgentEventSink): Result<?AgentRunOutcome> {
        let transition = match (control.pauseForApproval()) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let snapshot = RunSnapshot(request.runId, request.sessionId, RunState.WaitingApproval,
            sequence: context.currentSequence(), summary: "preparation read approval required",
            modelRequests: counter.modelRequests, usage: counter.usage(), lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens, lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls, turns: counter.turns)
        match (runs.save(snapshot)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (runs.saveContinuation(continuationFromRequest(request, approval))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (emitExtension(context, control, AgentEventKind.Approval, approvalRequestEventValue(approval), sink,
            toolCallId: Some(ToolCallId(approval.callId)), operationId: Some(approval.operationId))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (emitTransition(context, control, transition, sink)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(Some(AgentRunOutcome.AwaitingApproval(snapshot, approval)))
    }

    private func settleContextRead(context: ToolInvocationContext, control: CoreRunControl,
        owner: CoreContextReadOwner, prepared: PreparedToolInvocation,
        outcome: Result<ToolInvocationResult>, handedOff: Bool): Result<Unit> {
        let resolved = match (control.runtime.resolveOperation(ItemId("result-" + prepared.operationId.value),
            prepared.operationId, CanonicalToolCallId(prepared.call.callId), prepared.operationPlan,
            if (handedOff) { OperationAttemptStage.Executing } else { OperationAttemptStage.Prepared },
            outcome, "receipt-" + prepared.operationId.value, agentUtcMillis(),
            expectedRunId: Some(context.runId), expectedEpoch: Some(context.epoch))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (resolved.semanticCommit) { case Some(SemanticCommitDecision.Committed(_, _)) => ()
            case _ => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.read_result_uncommitted", "read result was not committed to its canonical Run")) }
        match (outcome) {
            case Result.Ok(ToolInvocationResult.Completed(result)) => if (!result.isError) {
                let fact = match (operationRuntime.loadContextReadFact(prepared.operationId, context.runId)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                match (owner.complete(context, fact)) { case Result.Err(error) => owner.deny(error.code); case Result.Ok(_) => () }
            } else { owner.deny("context.read_failed") }
            case Result.Ok(ToolInvocationResult.Denied(denial)) => owner.deny(denial.reason.code)
            case Result.Err(error) => owner.deny(error.code)
            case _ => owner.deny("context.read_terminal_invalid")
        }
        Result.Ok(())
    }

    private func resumeContextReadApproval(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, previous: RunSnapshot, approval: ApprovalRequest,
        decision: ApprovalDecision, sink: AgentEventSink): Result<AgentRunOutcome> {
        let pending = match (control.pendingRead(approval.operationId)) {
            case Some(value) => value; case None => return fail(request, context, control,
                AgentError(AgentErrorKind.RecoveryRequired, "context.read_live_owner_missing",
                    "read approval cannot recreate a lost Runtime source or replay a historical read"), sink) }
        if (pending.epoch != context.epoch || !pending.claim()) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_already_resuming", "read approval has another owner")) }
        let handoff = CoreExecutionHandoffState()
        let attempt = try { tools.decideContextRead(context, pending.prepared, decision,
            { _ => handoff.started = true; Result.Ok(()) }, decisionSource: approval.decisionSource) }
            catch (_: Exception) { Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Internal,
                "context.read_executor_failed", "context read executor failed without a verified terminal result")) }
        let settled = try { settleContextRead(context, control, pending.owner, pending.prepared, attempt, handoff.started) }
            finally {
                control.releasePendingRead(approval.operationId)
                let _ = releaseContextReadSlot(context, control, approval.operationId, sink)
            }
        match (settled) { case Result.Err(error) => return fail(request, context, control, error, sink); case Result.Ok(_) => () }
        let _ = emitDetail(context, AgentEventKind.Approval, approvalDecisionEventValue(approval, decision), sink)
        let counter = BudgetCounter(modelRequests: previous.modelRequests, inputTokens: previous.inputTokens,
            outputTokens: previous.outputTokens, reasoningTokens: previous.reasoningTokens,
            cacheReadTokens: previous.cacheReadTokens, cacheWriteTokens: previous.cacheWriteTokens,
            costMicros: previous.costMicros, lastInputTokens: previous.lastInputTokens,
            lastOutputTokens: previous.lastOutputTokens, lastRequestDurationMillis: previous.lastRequestDurationMillis,
            toolCalls: previous.toolCalls, turns: previous.turns)
        let calls = match (pendingCommittedToolCalls(control)) { case Result.Ok(value) => value
            case Result.Err(error) => return fail(request, context, control, error, sink, counter: Some(counter)) }
        match (runToolCalls(request, context, control, counter, calls, sink, CoreToolLoopState())) {
            case Result.Err(error) => return fail(request, context, control, error, sink, counter: Some(counter))
            case Result.Ok(Some(value)) => return Result.Ok(value)
            case Result.Ok(None) => ()
        }
        continueRun(request, context, control, counter, sink)
    }


    private func runToolBatch(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        calls: Array<CommittedToolCallRef>,
        sink: AgentEventSink,
        loopState: CoreToolLoopState
    ): Result<?AgentRunOutcome> {
        if (calls.isEmpty()) {
            return Result.Ok(None)
        }
        match (prepareToolReadInputs(request, context, control, counter, calls, sink)) {
            case Result.Ok(Some(waiting)) => return Result.Ok(Some(waiting))
            case Result.Ok(None) => ()
            case Result.Err(error) =>
                // No ordinary parent has been prepared by this stage. Resolve
                // every existing canonical parent before terminal Run handling;
                // failure to retain those facts is explicit recovery debt.
                match (settleReadPreparationParents(context, control, calls, error, sink)) {
                    case Result.Err(failure) => return Result.Err(failure); case Result.Ok(_) => () }
                return Result.Err(error)
        }
        // A cancelled preparation read has already consumed its one tool
        // charge. Settle its original committed parents without reserving or
        // preparing a new business operation after observing cancellation.
        if (hasReadPreparation(control, calls)) {
            match (control.source.token.check()) {
                case Result.Ok(_) => ()
                case Result.Err(cancelled) =>
                    match (control.beginCancellationSettlement(context.epoch)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(AgentError(
                            AgentErrorKind.RecoveryRequired, "context.read_cancel_phase_failed",
                            "cancelled preparation could not enter its durable settlement phase",
                            fields: [ErrorField("cause", error.code)]))
                    }
                    for (committed in calls) {
                        match (appendSkippedToolCall(context.sessionId, context, control, committed, sink,
                            errorCode: "tool.cancelled_during_preparation",
                            message: "preparation read was cancelled before this tool could execute",
                            cancellationSettlement: true)) {
                            case Result.Ok(_) => control.releasePreparationInput(committed.canonicalItemId)
                            case Result.Err(error) => return Result.Err(AgentError(
                                AgentErrorKind.RecoveryRequired, "context.read_parent_cancel_settlement_failed",
                                "cancelled preparation retained an unsettled canonical parent",
                                fields: [ErrorField("cause", error.code)]))
                        }
                    }
                    return Result.Err(cancelled)
            }
        }
        let batchId = control.nextBatchId()
        let coordinator = CoreToolBatchCoordinator(tools, toolHooks)
        let preparation = match (coordinator.prepare(
            context,
            calls,
            request.budget.maxConcurrentTools,
            { committed =>
                let block = committed.block
                match (reserveBudget(
                    control,
                    context,
                    BudgetCharge(toolCalls: 1),
                    sink,
                    toolBatchId: Some(batchId),
                    toolCallId: Some(ToolCallId(block.callId))
                )) {
                    case Result.Ok(_) =>
                        counter.toolCalls += 1
                    case Result.Err(error) => return Result.Err(error)
                }
                if (request.ownedEvents.isSome() && control.runtime.ownedCanonicalReadback().isSome()) {
                    return emitOwnedCanonicalToolStarted(context, control, committed, batchId,
                        request.ownedEvents.getOrThrow()) }
                emitExtension(
                    context,
                    control,
                    AgentEventKind.Tool,
                    objectValue(
                        [
                            ValueField(
                                "code",
                                textValue("tool.execution_started")
                            ),
                            ValueField("call_id", textValue(block.callId)),
                            ValueField("name", textValue(block.name)),
                            ValueField("arguments", block.arguments)
                        ]
                    ),
                    sink,
                    toolBatchId: Some(batchId),
                    toolCallId: Some(ToolCallId(block.callId))
                )
            }, preparationInput: { item => control.preparationInput(item) }
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                control.clearBatch(batchId)
                if (hasReadPreparation(control, calls)) {
                    match (settleReadPreparationParents(context, control, calls, error, sink)) {
                        case Result.Err(failure) => return Result.Err(failure); case Result.Ok(_) => () }
                }
                return Result.Err(error)
        }
        match (prepareCanonicalOperations(context, preparation)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                control.clearBatch(batchId)
                if (hasReadPreparation(control, calls)) {
                    match (settleReadPreparationParents(context, control, calls, error, sink, preparation: Some(preparation))) {
                        case Result.Err(failure) => return Result.Err(failure); case Result.Ok(_) => () }
                }
                return Result.Err(error)
        }
        executePreparedToolBatch(request,context,control,counter,preparation,sink,loopState,batchId)
    }

    // All operations in this suffix were already prepared and charged once.
    // Resumption executes those same sealed plans without another prepare.
    private func executePreparedToolBatch(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,counter:BudgetCounter,preparation:CoreToolBatchPreparation,
        sink:AgentEventSink,loopState:CoreToolLoopState,batchId:ToolBatchId):Result<?AgentRunOutcome> {
        let coordinator = CoreToolBatchCoordinator(tools,toolHooks)
        let execution = match (coordinator.execute(
            context,
            preparation,
            control.source.token,
            { work => control.registerScheduledToolSlot(
                work.prepared.operationId,
                work.block.name
            ) },
            { work =>
                let slotActive = control.unregisterScheduledToolSlot(
                    work.prepared.operationId
                )
                if (!slotActive) {
                    Result.Ok(())
                } else {
                    match (control.ledger.releaseTools()) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(usage) => emitTyped(
                            context,
                            control,
                            AgentEventPayload.BudgetUpdated(usage),
                            sink,
                            toolBatchId: Some(batchId)
                        )
                    }
                }
            },
            { count =>
                match (reserveBudget(
                    control,
                    context,
                    BudgetCharge(toolsStarted: count),
                    sink,
                    toolBatchId: Some(batchId)
                )) {
                    case Result.Ok(_) => Result.Ok(())
                    case Result.Err(error) => Result.Err(error)
                }
            },
            { count =>
                match (control.ledger.releaseTools(count: count)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(usage) => emitTyped(
                        context,
                        control,
                        AgentEventPayload.BudgetUpdated(usage),
                        sink,
                        toolBatchId: Some(batchId)
                    )
                }
            }
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                control.clearBatch(batchId)
                return Result.Err(error)
        }
        var fatal = execution.fatal
        try {
        for (item in execution.outcomes) {
            var canonicalCommitted = false
            match (commitCanonicalToolAttempt(control, item)) {
                case Result.Ok(_) => canonicalCommitted = true
                case Result.Err(error) => if (fatal.isNone()) {
                    fatal = Some(error)
                }
            }
            if (canonicalCommitted) {
                notifyPostToolHook(context, item)
                control.releasePreparationInput(item.committed.canonicalItemId)
            }
            match (item.result) {
                case Result.Err(error) => if (fatal.isNone()) {
                    fatal = Some(error)
                }
                case Result.Ok(actualOutcome) =>
                    let outcome = match (item.operationId) {
                        case Some(operationId) => canonicalRootToolResult(operationId, actualOutcome)
                        case None => actualOutcome
                    }
                    if (canonicalCommitted) {
                        match (emitToolOutcome(
                            context,
                            item.block.name,
                            outcome,
                            item.operationPlan.getOrThrow().canonicalArguments,
                            sink,
                            toolBatchId: Some(batchId),
                            toolCallId: Some(ToolCallId(item.block.callId))
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(error) => if (fatal.isNone()) {
                                fatal = Some(error)
                            }
                        }
                        match (afterCoreResultPersistedOwned113(
                            context,
                            control,
                            item.block.name,
                            outcome,
                            item.operationPlan,
                            primary: fatal.isNone()
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(error) => if (fatal.isNone()) {
                                fatal = Some(error)
                            }
                        }
                    }
                    updateCoreToolLoopState(loopState, item.block.name, outcome)
            }
        }
        } finally { for (item in execution.outcomes) { releaseToolInvocationPayload(item.result) } }
        match(execution.failedRetained){case Some(value)=>
            let debt=control.retainFailureCleanupDebt(value.output)
            if(value.output.outerErrorData333().isSome()){
                if(value.outerSettlementBlocked333){control.blockOuterPublication333()}
                match(value.outerSettlement333){case Some(error)=>let _=control.retainOuterSupplement333(error);case None=>()}
                match(fatal){case Some(error)=>let _=control.retainOuterSupplement333(error);case None=>()}
                control.clearBatch(batchId)
                return Result.Err(coreOwnedOuterErrorPending333())
            }
            let closed=value.output.closeAfterFailure()
            match(closed){case Result.Ok(_)=>control.releaseFailureCleanupDebt(debt);case Result.Err(_)=>()}
            control.clearBatch(batchId)
            return Result.Err(coreOwnedMergeSettlementError(value.error,match(closed){
                case Result.Err(error)=>Some(error);case Result.Ok(_)=>fatal}))
            case None=>()}
        match(execution.retained){
            case Some(value)=>
                // Even a scheduler failure after Known completion cannot
                // erase its real canonical receipt or physical cleanup debt.
                let settlement=match(value.settlementError){case Some(error)=>Some(coreOwnedMergeSettlementError(error,fatal));case None=>fatal}
                match(consumeRetainedOwnedParentOutcome(context,control,value.work,value.output,
                    if(value.handoffStarted){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},sink,loopState,retainedBatchId:Some(batchId),ownedEvents:request.ownedEvents)){
                    case Result.Err(error)=>control.clearBatch(batchId);return Result.Err(coreOwnedMergeSettlementError(error,settlement))
                    case Result.Ok(_)=>()}
                match(settlement){case Some(error)=>control.clearBatch(batchId);return Result.Err(error);case None=>()}
                return executePreparedToolBatch(request,context,control,counter,value.remaining,sink,loopState,batchId)
            case None=>()
        }
        if (control.source.token.isCancelled() && fatal.isNone()) {
            fatal = Some(controlCancellationError(control))
        }
        match (fatal) {
            case Some(error) =>
                control.clearBatch(batchId)
                return Result.Err(error)
            case None => ()
            }
             match (execution.waiting) {
                 case Some(value) => return publishOwnedExecutionApproval(request,context,control,counter,
                     value,sink,batchId)
                 case None => ()
             }
             match ((preparation.approvalPrepared,preparation.approvalCall)) {
                 case (Some(parent),Some(committed)) =>
                     if ((isPluginLivePolicyParentPlan(parent.operationPlan) || isManagedChannelOwnedParentPlan(parent.operationPlan))) {
                         let retained = CorePendingOwnedParentApproval(CorePreparedTool(0,committed,parent))
                         match (control.retainPendingOwnedParent(retained)) {
                             case Result.Err(error) => control.clearBatch(batchId); return Result.Err(error)
                             case Result.Ok(_) => ()
                         }
                     }
                 case _ => ()
             }
             match (preparation.approval) {
                 case Some(approval) =>
                let waiting = match (control.pauseForApproval()) {
                    case Result.Ok(value) => value
                    case Result.Err(error) =>
                        control.clearBatch(batchId)
                        return Result.Err(error)
                }
                match (emitExtension(
                    context,
                    control,
                    AgentEventKind.Approval,
                    approvalRequestEventValue(approval),
                    sink,
                    toolBatchId: Some(batchId),
                    toolCallId: Some(ToolCallId(approval.callId)),
                    operationId: Some(approval.operationId)
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        control.clearBatch(batchId)
                        return Result.Err(error)
                }
                let snapshot = RunSnapshot(
                    request.runId,
                    request.sessionId,
                    RunState.WaitingApproval,
                    sequence: context.currentSequence(),
                    summary: "tool approval required",
                    modelRequests: counter.modelRequests,
                    usage: counter.usage(),
                    lastInputTokens: counter.lastInputTokens,
                    lastOutputTokens: counter.lastOutputTokens,
                    lastRequestDurationMillis: counter.lastRequestDurationMillis,
                    toolCalls: counter.toolCalls,
                    turns: counter.turns
                )
                match (runs.save(snapshot)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        control.clearBatch(batchId)
                        return Result.Err(error)
                }
                match (runs.saveContinuation(
                    continuationFromRequest(request, approval)
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        control.clearBatch(batchId)
                        return Result.Err(error)
                }
                match (emitTransition(context, control, waiting, sink)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        control.clearBatch(batchId)
                        return Result.Err(error)
                }
                control.clearBatch(batchId)
                Result.Ok(Some(AgentRunOutcome.AwaitingApproval(
                    snapshot,
                    approval
                )))
            case None =>
                control.clearBatch(batchId)
                Result.Ok(None)
        }
    }

    private func publishOwnedExecutionApproval(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,counter:BudgetCounter,pending:CorePendingOwnedExecution,
        sink:AgentEventSink,batchId:ToolBatchId,alreadyRetained!:Bool=false):Result<?AgentRunOutcome> {
        if(pending.publication.isPreparedPhase()){
            return pending.publication.withPreparedApproval({approval=>
                publishPreparedExecutionApprovalFrame(request,context,control,counter,pending,approval,sink,batchId,alreadyRetained)})}
        let approval=pending.publication.continuation.approval
        if (control.state()!=RunState.Running || !pending.matches(context,approval)) {
            control.clearBatch(batchId);return Result.Err(coreOwnedLiveOwnerMissing()) }
        // Running-only complete paid Store proof occurs after all siblings'
        // canonical commit and actual payload ACK, before waiting publication.
        match (tools.validateOwnedExecutionPublication(context,pending.publication)) {
            case Result.Err(error) => control.clearBatch(batchId);return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (!alreadyRetained) {
            match (control.retainPendingOwnedExecution(pending)) {
                case Result.Err(error) => control.clearBatch(batchId);return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        // A failure below retains the same actual Core reference and Host
        // collector debt. It neither clears custody nor fabricates a result.
        try {
            let transition=match(control.pauseForApproval()) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error))
                case Result.Ok(value) => value
            }
            let snapshot=RunSnapshot(request.runId,request.sessionId,RunState.WaitingApproval,
                sequence:context.currentSequence(),summary:"plugin child approval required",
                modelRequests:counter.modelRequests,usage:counter.usage(),lastInputTokens:counter.lastInputTokens,
                lastOutputTokens:counter.lastOutputTokens,lastRequestDurationMillis:counter.lastRequestDurationMillis,
                toolCalls:counter.toolCalls,turns:counter.turns)
            match (runs.save(snapshot)) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (runs.saveContinuation(continuationFromRequest(request,approval))) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (emitExtension(context,control,AgentEventKind.Approval,approvalRequestEventValue(approval),sink,
                toolBatchId:Some(batchId),toolCallId:Some(ToolCallId(approval.callId)),operationId:Some(approval.operationId))) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (emitTransition(context,control,transition,sink)) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            Result.Ok(Some(AgentRunOutcome.AwaitingApproval(snapshot,approval)))
        } finally { control.clearBatch(batchId) }
    }

    private func publishPreparedExecutionApprovalFrame(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,counter:BudgetCounter,pending:CorePendingOwnedExecution,approval:ApprovalRequest,
        sink:AgentEventSink,batchId:ToolBatchId,alreadyRetained:Bool):Result<?AgentRunOutcome> {
        if (control.state()!=RunState.Running || !pending.matches(context,approval)) {
            control.clearBatch(batchId);return Result.Err(coreOwnedLiveOwnerMissing()) }
        // Running-only complete paid Store proof occurs after all siblings'
        // canonical commit and actual payload ACK, before waiting publication.
        match (tools.validateOwnedExecutionPublication(context,pending.publication)) {
            case Result.Err(error) => control.clearBatch(batchId);return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (!alreadyRetained) {
            match (control.retainPendingOwnedExecution(pending)) {
                case Result.Err(error) => control.clearBatch(batchId);return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        // A failure below retains the same actual Core reference and Host
        // collector debt. It neither clears custody nor fabricates a result.
        try {
            let transition=match(control.pauseForApproval()) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error))
                case Result.Ok(value) => value
            }
            let snapshot=RunSnapshot(request.runId,request.sessionId,RunState.WaitingApproval,
                sequence:context.currentSequence(),summary:"plugin child approval required",
                modelRequests:counter.modelRequests,usage:counter.usage(),lastInputTokens:counter.lastInputTokens,
                lastOutputTokens:counter.lastOutputTokens,lastRequestDurationMillis:counter.lastRequestDurationMillis,
                toolCalls:counter.toolCalls,turns:counter.turns)
            match (runs.save(snapshot)) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (runs.saveContinuation(continuationFromRequest(request,approval))) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (emitExtension(context,control,AgentEventKind.Approval,approvalRequestEventValue(approval),sink,
                toolBatchId:Some(batchId),toolCallId:Some(ToolCallId(approval.callId)),operationId:Some(approval.operationId))) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            match (emitTransition(context,control,transition,sink)) {
                case Result.Err(error) => return Result.Err(coreOwnedPublicationFailure(error));case Result.Ok(_) => () }
            Result.Ok(Some(AgentRunOutcome.AwaitingApproval(snapshot,approval)))
        } finally { control.clearBatch(batchId) }
    }

    private func resumeOwnedExecutionApproval(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,previous:RunSnapshot,approval:ApprovalRequest,decision:ApprovalDecision,
        pending:CorePendingOwnedExecution,sink:AgentEventSink):Result<AgentRunOutcome> {
        let counter=coreOwnedCounter(previous)
        if (control.state()!=RunState.Running || !pending.matches(context,approval) || !pending.claim()) {
            return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter)) }
        // Tools repeats its full Source/current/fence/ledger proof now that
        // this same original Run is genuinely running. It approves only the
        // same prepared child and consumes its private resume claim once.
        let slot=withOwnedApprovalToolSlot(context,control,pending.work.prepared.operationId,
            pending.work.block.name,sink,{=>tools.resumeOwnedPrepared(context,pending.publication,decision,
                decisionSource:approval.decisionSource)})
        let progress=slot.progress
        let loopState=CoreToolLoopState()
        match (progress) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Waiting(publication)) =>
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
                let next=CorePendingOwnedExecution(CorePreparedTool(pending.work.index,pending.work.committed,
                    (if(publication.isPreparedPhase()){publication.preparedParent().value().getOrThrow()}else{publication.continuation.parent})),publication,pending.remaining)
                match (control.replacePendingOwnedExecution(pending,next)) {
                    case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
                    case Result.Ok(_) => ()
                }
                match (publishOwnedExecutionApproval(request,context,control,counter,next,sink,control.nextBatchId(),alreadyRetained:true)) {
                    case Result.Ok(Some(value)) => return Result.Ok(value)
                    case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
                    case _ => return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter))
                }
            case Result.Ok(OwnedToolPipelineProgress.FailedRetained(result,error)) =>
                let debt=control.retainFailureCleanupDebt(result)
                if(result.outerErrorData333().isSome()){
                    match(slot.settlementError){case Some(value)=>let _=control.retainOuterSupplement333(value);case None=>()}
                    return fail(request,context,control,coreOwnedOuterErrorPending333(),sink,counter:Some(counter))
                }
                let closed=result.closeAfterFailure()
                match(closed){case Result.Ok(_)=>control.releaseFailureCleanupDebt(debt);case Result.Err(_)=>()}
                return fail(request,context,control,coreOwnedMergeSettlementError(error,match(closed){
                    case Result.Err(failure)=>Some(failure);case Result.Ok(_)=>slot.settlementError}),sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Retained(result)) =>
                match(consumeRetainedOwnedParentOutcome(context,control,pending.work,result,OperationAttemptStage.Executing,sink,loopState,ownedEvents:request.ownedEvents)){
                    case Result.Err(error)=>return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
                    case Result.Ok(_)=>control.releasePendingOwnedExecution(pending)}
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
            case Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error)) =>
                match(consumeRetainedOwnedParentOutcome(context,control,pending.work,result,OperationAttemptStage.Executing,sink,loopState,ownedEvents:request.ownedEvents)){
                    case Result.Err(failure)=>return fail(request,context,control,coreOwnedMergeSettlementError(failure,Some(error)),sink,counter:Some(counter))
                    case Result.Ok(_)=>control.releasePendingOwnedExecution(pending)}
                return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Completed(result)) =>
                match (commitOwnedParentOutcome(context,control,pending.work,result,OperationAttemptStage.Executing,sink,loopState)) {
                    case Result.Err(error) => return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
                    case Result.Ok(_) => control.releasePendingOwnedExecution(pending)
                }
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
            case Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)) =>
                let known=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)),
                    settlementError:slot.settlementError)
                match (known.progress) {
                    case Result.Ok(OwnedToolPipelineProgress.Completed(value)) =>
                        match (commitOwnedParentOutcome(context,control,pending.work,value,OperationAttemptStage.Executing,sink,loopState)) {
                            case Result.Err(failure) => return fail(request,context,control,coreOwnedMergeSettlementError(failure,known.settlementError),sink,counter:Some(counter))
                            case Result.Ok(_) => control.releasePendingOwnedExecution(pending)
                        }
                    case Result.Err(failure) => return fail(request,context,control,failure,sink,counter:Some(counter))
                    case _ => return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter))
                }
                return fail(request,context,control,known.settlementError.getOrThrow(),sink,counter:Some(counter))
        }
        // These suffix operations already have their original preparation,
        // Source and tool-call charge. Execute them without re-preparation.
        match (executePreparedToolBatch(request,context,control,counter,pending.remaining,sink,loopState,control.nextBatchId())) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(Some(value)) => return Result.Ok(value)
            case Result.Ok(None) => ()
        }
        let remaining=match(pendingCommittedToolCalls(control)) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(value) => value
        }
        match (runToolCalls(request,context,control,counter,remaining,sink,loopState)) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(Some(value)) => return Result.Ok(value);case Result.Ok(None) => ()
        }
        continueRun(request,context,control,counter,sink,toolLoopState:Some(loopState))
    }

    private func resumeOwnedParentApproval(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,previous:RunSnapshot,approval:ApprovalRequest,decision:ApprovalDecision,
        pending:CorePendingOwnedParentApproval,sink:AgentEventSink):Result<AgentRunOutcome> {
        let counter=coreOwnedCounter(previous)
        if (control.state()!=RunState.Running || !pending.claim()) {
            return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter)) }
        let handoff=CoreExecutionHandoffState()
        let slot=withOwnedApprovalToolSlot(context,control,pending.work.prepared.operationId,pending.work.block.name,sink,
            {=>tools.decideOwnedPrepared(context,pending.work.prepared,decision,decisionSource:approval.decisionSource,
                afterHandoff:{_=>handoff.started=true;Result.Ok(())})})
        let progress=slot.progress
        let loopState=CoreToolLoopState()
        match (progress) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Waiting(publication)) =>
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
                if (!handoff.started) { return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter)) }
                let next=CorePendingOwnedExecution(CorePreparedTool(pending.work.index,pending.work.committed,
                    (if(publication.isPreparedPhase()){publication.preparedParent().value().getOrThrow()}else{publication.continuation.parent})),publication,CoreToolBatchPreparation([],[],None,None,None,[]))
                match (control.replacePendingOwnedParentWithExecution(pending,next)) {
                    case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
                    case Result.Ok(_) => ()
                }
                match (publishOwnedExecutionApproval(request,context,control,counter,next,sink,control.nextBatchId(),alreadyRetained:true)) {
                    case Result.Ok(Some(value)) => return Result.Ok(value)
                    case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
                    case _ => return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter))
                }
            case Result.Ok(OwnedToolPipelineProgress.FailedRetained(result,error)) =>
                let debt=control.retainFailureCleanupDebt(result)
                if(result.outerErrorData333().isSome()){
                    match(slot.settlementError){case Some(value)=>let _=control.retainOuterSupplement333(value);case None=>()}
                    return fail(request,context,control,coreOwnedOuterErrorPending333(),sink,counter:Some(counter))
                }
                let closed=result.closeAfterFailure()
                match(closed){case Result.Ok(_)=>control.releaseFailureCleanupDebt(debt);case Result.Err(_)=>()}
                return fail(request,context,control,coreOwnedMergeSettlementError(error,match(closed){
                    case Result.Err(failure)=>Some(failure);case Result.Ok(_)=>slot.settlementError}),sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Retained(result)) =>
                match(consumeRetainedOwnedParentOutcome(context,control,pending.work,result,
                    if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},sink,loopState,ownedEvents:request.ownedEvents)){
                    case Result.Err(error)=>return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
                    case Result.Ok(_)=>control.releasePendingOwnedParent(pending)}
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
            case Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error)) =>
                match(consumeRetainedOwnedParentOutcome(context,control,pending.work,result,
                    if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},sink,loopState,ownedEvents:request.ownedEvents)){
                    case Result.Err(failure)=>return fail(request,context,control,coreOwnedMergeSettlementError(failure,Some(error)),sink,counter:Some(counter))
                    case Result.Ok(_)=>control.releasePendingOwnedParent(pending)}
                return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
            case Result.Ok(OwnedToolPipelineProgress.Completed(result)) =>
                match (commitOwnedParentOutcome(context,control,pending.work,result,
                    if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},sink,loopState)) {
                    case Result.Err(error) => return fail(request,context,control,coreOwnedMergeSettlementError(error,slot.settlementError),sink,counter:Some(counter))
                    case Result.Ok(_) => control.releasePendingOwnedParent(pending)
                }
                match(slot.settlementError){case Some(error)=>return fail(request,context,control,error,sink,counter:Some(counter));case None=>()}
            case Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)) =>
                let known=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)),
                    settlementError:slot.settlementError)
                match (known.progress) {
                    case Result.Ok(OwnedToolPipelineProgress.Completed(value)) =>
                        match (commitOwnedParentOutcome(context,control,pending.work,value,
                            if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},sink,loopState)) {
                            case Result.Err(failure) => return fail(request,context,control,coreOwnedMergeSettlementError(failure,known.settlementError),sink,counter:Some(counter))
                            case Result.Ok(_) => control.releasePendingOwnedParent(pending)
                        }
                    case Result.Err(failure) => return fail(request,context,control,failure,sink,counter:Some(counter))
                    case _ => return fail(request,context,control,coreOwnedLiveOwnerMissing(),sink,counter:Some(counter))
                }
                return fail(request,context,control,known.settlementError.getOrThrow(),sink,counter:Some(counter))
        }
        let remaining=match(pendingCommittedToolCalls(control)) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(value) => value
        }
        match (runToolCalls(request,context,control,counter,remaining,sink,loopState)) {
            case Result.Err(error) => return fail(request,context,control,error,sink,counter:Some(counter))
            case Result.Ok(Some(value)) => return Result.Ok(value);case Result.Ok(None) => ()
        }
        continueRun(request,context,control,counter,sink,toolLoopState:Some(loopState))
    }

    private func commitOwnedParentOutcome(context:ToolInvocationContext,control:CoreRunControl,
        work:CorePreparedTool,result:Result<ToolInvocationResult>,stage:OperationAttemptStage,
        sink:AgentEventSink,loopState:CoreToolLoopState,
        releasePayload!:Bool=true,onCanonicalPersisted!:()->Unit={=>()},
        retainedBatchId!:?ToolBatchId=None<ToolBatchId>):Result<Unit> {
        let item=CoreToolOutcome(work.index,work.committed,result,operationId:Some(work.prepared.operationId),
            operationPlan:Some(work.prepared.operationPlan),attemptStage:stage,knownParentPrepared:if(isPluginLivePolicyParentPlan(work.prepared.operationPlan) || isManagedChannelOwnedParentPlan(work.prepared.operationPlan)){Some(work.prepared)}else{None})
        try {
            match (commitCanonicalToolAttempt(control,item)) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            onCanonicalPersisted()
            notifyPostToolHook(context,item)
            control.releasePreparationInput(work.committed.canonicalItemId)
            match (result) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) =>
                    let outcome=canonicalRootToolResult(work.prepared.operationId,value)
                    // Canonical receipt/result belongs to the original Parent,
                    // never the child approval operation or its call ID.
                    match (emitToolOutcome(context,work.block.name,outcome,work.prepared.operationPlan.canonicalArguments,sink,
                        toolBatchId:retainedBatchId,
                        toolCallId:Some(ToolCallId(work.block.callId)))) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match (afterCoreResultPersistedOwned113(context,control,work.block.name,outcome,Some(work.prepared.operationPlan))) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    updateCoreToolLoopState(loopState,work.block.name,outcome)
            }
            Result.Ok(())
        } finally { if(releasePayload){releaseToolInvocationPayload(result)} }
    }

    private func consumeRetainedOwnedParentOutcome(context:ToolInvocationContext,control:CoreRunControl,
        work:CorePreparedTool,output:OwnedToolRetainedParentExecution,stage:OperationAttemptStage,
        sink:AgentEventSink,loopState:CoreToolLoopState,
        retainedBatchId!:?ToolBatchId=None<ToolBatchId>,
        ownedEvents!:?OwnedAgentEventSink=None<OwnedAgentEventSink>):Result<Unit>{
        if (ownedEvents.isSome() && control.runtime.ownedCanonicalReadback().isSome()) {
            return consumeOwnedCanonicalReadbackOutcome(context, control, work, output, stage,
                loopState, ownedEvents.getOrThrow(), retainedBatchId)
        }
        let debt=control.retainResultAckDebt(output)
        match(output.prepareCanonicalBacking()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let flag=CoreRetainedCanonicalCommitFlag()
        let consumed=output.withOutput({actual=>
            commitOwnedParentOutcome(context,control,work,Result.Ok(ToolInvocationResult.Completed(actual)),
                stage,sink,loopState,releasePayload:false,onCanonicalPersisted:{=>flag.committed=true},retainedBatchId:retainedBatchId)})
        // Actual ToolResult, CoreToolOutcome and all canonical/event/hook
        // temporary references above ended before the real physical close.
        if(!flag.committed){return consumed}
        control.markResultCanonicalCommitted(debt)
        let closed=output.closeAfterConsumption()
        match(closed){case Result.Err(error)=>return Result.Err(coreOwnedMergeSettlementError(error,
            match(consumed){case Result.Err(cause)=>Some(cause);case Result.Ok(_)=>None}))
            case Result.Ok(_)=>control.releaseResultAckDebt(debt)}
        consumed
    }

    private func consumeOwnedCanonicalReadbackOutcome(context: ToolInvocationContext,
        control: CoreRunControl, work: CorePreparedTool, output: OwnedToolRetainedParentExecution,
        stage: OperationAttemptStage, loopState: CoreToolLoopState, sink: OwnedAgentEventSink,
        retainedBatchId: ?ToolBatchId): Result<Unit> {
        // Adopt the actual returned output before any opt-in contract can
        // reject this path. Cleanup then remains owned even before commit.
        let debt = control.retainResultAckDebt(output)
        let repository = match (runs as OwnedRunEventRepository) {
            case Some(value) => value
            case None => return coreOwnedCanonicalDeliveryError("tool.canonical_repository_owned_contract_missing") }
        let hooks = match (toolHooks as OwnedCoreToolHookRuntime) {
            case Some(value) => value
            case None => return coreOwnedCanonicalDeliveryError("tool.canonical_hook_owned_contract_missing") }
        match (output.prepareCanonicalBacking()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let capture = CoreOwnedCanonicalCapture()
        let consumed = output.withOutput({ actual =>
            let outcome = CoreToolOutcome(work.index, work.committed,
                Result.Ok(ToolInvocationResult.Completed(actual)), operationId: Some(work.prepared.operationId),
                operationPlan: Some(work.prepared.operationPlan), attemptStage: stage,
                knownParentPrepared: if (isPluginLivePolicyParentPlan(work.prepared.operationPlan) ||
                    isManagedChannelOwnedParentPlan(work.prepared.operationPlan)) { Some(work.prepared) } else { None })
            match (commitCanonicalToolAttempt(control, outcome)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            capture.committed = true; capture.lease = actual.payloadLease
            control.releasePreparationInput(work.committed.canonicalItemId)
            Result.Ok(()) })
        // Full ToolResult/outcome/envelope/transition/commit return frames ended.
        // Physical output ACK still does not retire permanent Prepared/input
        // aliases. The original canonical backing remains safely pinned.
        if (!capture.committed) { return consumed }
        control.markResultCanonicalCommitted(debt)
        match (output.closeAfterConsumption()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!output.isAcknowledged() || capture.lease.isNone()) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_output_ack_pending") }
        control.releaseResultAckDebt(debt)
        let record = match (control.runtime.takeOwnedCanonicalRetirement(capture.lease.getOrThrow())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let guard: () -> Result<Unit> = { => context.cancellation.check() }
        let post = CoreOwnedPostToolFactory(work)
        let postDelivery = CoreOwnedCanonicalObserverDelivery(record, guard,
            { held => hooks.afterOwnedTool(context, work.committed, { item => post.value(item) }, held) })
        control.retainCanonicalDelivery(postDelivery)
        // Keep old post-hook-before-event order. Typed ownership failure stops
        // the next compute; it never changes the already canonical receipt.
        match (postDelivery.run()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        control.releaseCanonicalDelivery(postDelivery)
        match (control.serializeEvent({ =>
            let meta = EventMeta(context.nextSequence(), control.traceId, context.runId,
                occurredAtMillis: agentUtcMillis(), turnId: control.currentTurnId(),
                requestId: match (control.currentRequestId()) { case "" => None; case value => Some(RequestId(value)) },
                toolBatchId: match (retainedBatchId) { case Some(value) => Some(value); case None => control.currentBatchId() },
                toolCallId: Some(ToolCallId(work.block.callId)), operationId: Some(work.prepared.operationId))
            let factory = CoreOwnedToolResultPayloadFactory(work.block.name, ToolCallId(work.block.callId),
                work.prepared.operationId, "receipt-" + work.prepared.operationId.value)
            let delivery = CoreOwnedCanonicalEventDelivery(record, guard, repository, sink, meta, factory)
            control.retainCanonicalDelivery(delivery)
            match (delivery.run()) { case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => control.releaseCanonicalDelivery(delivery); Result.Ok(()) }
        })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let persisted = CoreOwnedCanonicalObserverDelivery(record, guard,
            { held => tools.afterOwnedResultPersisted(context, work.block.name, held) })
        control.retainCanonicalDelivery(persisted)
        match (persisted.run()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        control.releaseCanonicalDelivery(persisted)
        // Every readback delivery above has ended, so this record's original
        // result allocation is no longer needed. The coordinator already
        // removed it from its index when it was taken, so closing retires its
        // actual payload lease and returns that charge to the same shared
        // bank instead of holding it for the life of the thread. Retiring it
        // grants no Source, Known result, receipt or effect.
        record.close()
        // This route accepts only Completed. The original loop-state switch
        // resets this counter for every Completed, after event/hook success;
        // it retains no result field and does not alter the previous tool name.
        loopState.consecutiveCapabilityDenials = 0
        consumed
    }

    // Cleanup only, valid even after cancellation/stale Source. It cannot
    // replay an effect or commit a pending canonical result. Same actual Run
    // owner and allocation are retained until checked ACK succeeds.
    public func retryRetainedToolResultCleanup(runId:RunId):Result<Unit>{
        let control=match(controls.find(runId)){case Some(value)=>value;case None=>return Result.Ok(())}
        match(control.retryResultAckDebt()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(isTerminalRunState(control.state())){finishControl(runId)}
        Result.Ok(())
    }

    private func withOwnedApprovalToolSlot(context:ToolInvocationContext,control:CoreRunControl,
        operation:OperationId,tool:String,sink:AgentEventSink,action:()->Result<OwnedToolPipelineProgress>):CoreOwnedSlotProgress {
        let lease=match(coreAcquireOwnedResumeSlot(control,operation,tool)) {
            case Result.Err(error)=>return CoreOwnedSlotProgress(Result.Err(error));case Result.Ok(value)=>value }
        let progress:Result<OwnedToolPipelineProgress> = try {
            match (emitTyped(context,control,AgentEventPayload.BudgetUpdated(control.ledger.snapshot()),sink)) {
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>match(context.cancellation.check()){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>action()}
            }
        } catch (_:Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "tool.live_resume_unsettled","owned continuation did not return a verified state")) }
        try {
            match (lease.release()) {
                case Result.Err(error)=>return CoreOwnedSlotProgress(progress,settlementError:Some(error))
                case Result.Ok(_)=>()
            }
            match (emitTyped(context,control,AgentEventPayload.BudgetUpdated(control.ledger.snapshot()),sink)) {
                case Result.Err(error)=>return CoreOwnedSlotProgress(progress,settlementError:Some(error))
                case Result.Ok(_)=>()
            }
        } catch (_:Exception) {
            // An external event sink can throw after the actual owned driver
            // has returned. Preserve that verified result for Parent commit
            // and ACK; neither event failure nor slot cleanup retries effects.
            return CoreOwnedSlotProgress(progress,settlementError:Some(AgentError(
                AgentErrorKind.RecoveryRequired,"tool.live_resume_settlement_failed",
                "owned continuation scheduler or event settlement failed")))
        }
        // A verified Completed result survives scheduler/event failure so
        // its original-parent canonical commit/ACK occurs before failure.
        // Waiting failure retains the original Host collector debt and cannot
        // publish approval or ACK a nonexistent terminal parent result.
        CoreOwnedSlotProgress(progress)
    }

    private func updateCoreToolLoopState(
        state: CoreToolLoopState,
        toolName: String,
        outcome: ToolInvocationResult
    ): Unit {
        match (outcome) {
            case ToolInvocationResult.Denied(denial) =>
                if (denial.reason.code == "tool.capability_denied") {
                    state.consecutiveCapabilityDenials += 1
                    state.lastCapabilityDeniedTool = toolName
                } else {
                    state.consecutiveCapabilityDenials = 0
                }
            case _ => state.consecutiveCapabilityDenials = 0
        }
    }

    private func prepareCanonicalOperations(
        context: ToolInvocationContext,
        preparation: CoreToolBatchPreparation
    ): Result<Unit> {
        for (wave in preparation.waves) {
            for (work in wave.calls) {
                match (prepareCanonicalOperation(context, work.committed, work.prepared)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        for (outcome in preparation.immediate) {
            let operationId = match (outcome.operationId) {
                case Some(value) => value
                case None => OperationId(
                    "operation-immediate-" + outcome.committed.decisionId.value + "-" +
                        outcome.committed.scopedToolCallId.value
                )
            }
            let plan = match (outcome.operationPlan) {
                case Some(value) => value
                case None => canonicalImmediatePlan(context, outcome.block)
            }
            match (operationRuntime.prepare(
                operationId,
                context.runId,
                outcome.committed,
                plan
            )) {
                case Result.Ok(_) => outcome.bindOperation(
                    operationId, plan, OperationAttemptStage.Prepared
                )
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match ((preparation.approvalPrepared, preparation.approvalCall)) {
            case (Some(prepared), Some(committed)) =>
                match (prepareCanonicalOperation(context, committed, prepared)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                // The NEW persist operation proved and atomically wrote
                // its exact waiting state. Repeating the legacy transition
                // would reject an already-waiting actual SQLite operation.
                if ((isPluginLivePolicyParentPlan(prepared.operationPlan) || isManagedChannelOwnedParentPlan(prepared.operationPlan))) { return Result.Ok(()) }
                operationRuntime.waitForApproval(
                    prepared.operationId, context.runId
                )
            case (None, None) => Result.Ok(())
            case _ => Result.Err(AgentError(
                AgentErrorKind.Internal,
                "operation.approval_binding_missing",
                "approval preparation lost its normalized Operation"
            ))
        }
    }

    private func prepareCanonicalOperation(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        prepared: PreparedToolInvocation
    ): Result<Unit> {
        if ((isPluginLivePolicyParentPlan(prepared.operationPlan) || isManagedChannelOwnedParentPlan(prepared.operationPlan))) {
            return tools.persistOwnedPrepared(context,prepared)
        }
        operationRuntime.prepare(
            prepared.operationId,
            context.runId,
            committed,
            prepared.operationPlan
        )
    }

    private func canonicalImmediatePlan(
        context: ToolInvocationContext,
        block: ModelBlock
    ): NormalizedOperationPlan {
        let call = ToolCall(block.callId, block.name, block.arguments)
        try {
            match (catalog.resolvedDescriptor(call, threadId: Some(ThreadId(context.sessionId.value)))) {
                case Some(descriptor) => normalizedToolOperationPlan(
                    context, call, descriptor
                )
                case None => canonicalRejectedPlan(context, block)
            }
        } catch (_: IllegalArgumentException) {
            // Invalid resolver output is already a denied ToolPreparation. Keep
            // that denial inside the canonical Operation boundary instead of
            // rethrowing while deriving the immediate fallback plan.
            canonicalRejectedPlan(context, block)
        }
    }

    private func canonicalRejectedPlan(
        context: ToolInvocationContext,
        block: ModelBlock
    ): NormalizedOperationPlan {
        NormalizedOperationPlan(
            block.name,
            block.arguments,
            [],
            OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never,
            "rejected-" + context.runId.value + "-" + block.callId
        )
    }


    private func notifyPostToolHook(
        context: ToolInvocationContext,
        outcome: CoreToolOutcome
    ): Unit {
        let operationId = match (outcome.operationId) {
            case Some(value) => value
            case None => return
        }
        let plan = match (outcome.operationPlan) {
            case Some(value) => value
            case None => return
        }
        let receiptId = "receipt-" + operationId.value
        var terminalOutcome = "failed"
        var resultValue: ?AgentValue = None
        match (outcome.result) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                terminalOutcome = if (result.isError) { "failed" } else { "completed" }
                resultValue = Some(result.output)
            case Result.Ok(ToolInvocationResult.Denied(denial)) =>
                terminalOutcome = "denied"
                resultValue = Some(objectValue([
                    ValueField("code", textValue(denial.reason.code)),
                    ValueField("message", textValue(denial.reason.message))
                ]))
            case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
                terminalOutcome = "denied"
            case Result.Err(error) =>
                terminalOutcome = if (error.kind == AgentErrorKind.Cancelled) {
                    "cancelled"
                } else { "failed" }
                resultValue = Some(objectValue([
                    ValueField("code", textValue(error.code)),
                    ValueField("message", textValue(error.message))
                ]))
        }
        let event = CoreToolHookPostEvent(
            outcome.block.name,
            plan.canonicalArguments,
            operationId.value,
            receiptId,
            terminalOutcome,
            plan.requiredCapabilities,
            result: resultValue
        )
        try {
            toolHooks.afterTool(context, outcome.committed, event)
        } catch (_: Exception) {
            // Observer failure cannot alter a committed result or its receipt.
        }
    }

    // Preserve the executor's data and its single allocation lease while
    // exposing the canonical Receipt reserved for this actual root Operation.
    private func canonicalRootToolResult(operationId: OperationId,
        outcome: ToolInvocationResult): ToolInvocationResult {
        match (outcome) {
            case ToolInvocationResult.Completed(result) =>
                ToolInvocationResult.Completed(ToolResult(result.callId, result.output,
                    isError: result.isError, receiptId: "receipt-" + operationId.value,
                    payloadLease: result.payloadLease))
            case _ => outcome
        }
    }

     private func commitCanonicalToolAttempt(
        control: CoreRunControl,
        outcome: CoreToolOutcome
    ): Result<Unit> {
        let operationId = match (outcome.operationId) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "operation.binding_missing",
                "tool outcome has no canonical Operation binding"
            ))
        }
        let plan = outcome.operationPlan.getOrThrow()
        let receiptId = "receipt-" + operationId.value
        let canonicalResult: Result<ToolInvocationResult> = match (outcome.result) {
            case Result.Ok(value) => Result.Ok(canonicalRootToolResult(operationId, value))
            case Result.Err(error) => Result.Err(error)
        }
        // Projection persistence may fail after the canonical SQLite/in-memory
        // commit. Retrying the same approval must replay that semantic fact,
        // not append a second ToolResult or consume another result sequence.
        match (control.runtime.ownedCanonicalReadback()) {
            case Some(reader) =>
                let metadata = control.runtime.threadMetadataSnapshot()
                let probe = CoreOwnedCanonicalReplayProbe(operationId, outcome.block.callId, receiptId)
                match (reader.visit(metadata.thread.id, metadata.thread.revision, 0,
                    { => control.source.token.check() }, { item, _ => probe.read(item) })) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (probe.found) { return Result.Ok(()) }
            case None =>
        for (item in control.runtime.threadSnapshot().items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(callId, existingOperationId,
                    existingReceiptId, _, _) =>
                    if (existingOperationId.value == operationId.value) {
                        if (callId.value == outcome.block.callId &&
                            existingReceiptId == receiptId) {
                            return Result.Ok(())
                        }
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "operation.semantic_replay_drift",
                            "Operation already committed a different canonical ToolResult"
                        ))
                    }
                case _ => ()
            }
        }
        }
        let resolved = match (control.runtime.resolveOperation(
            ItemId(
                "result-" + operationId.value
            ),
            operationId,
            CanonicalToolCallId(outcome.block.callId),
            plan,
            outcome.attemptStage,
            canonicalResult,
            receiptId,
            agentUtcMillis(),
            knownParentSource:match(outcome.knownParentPrepared){case Some(actual)=>
                if(outcome.attemptStage==OperationAttemptStage.Executing &&
                    (isPluginLivePolicyParentPlan(actual.operationPlan) || isManagedChannelOwnedParentPlan(actual.operationPlan))){
                    match(outcome.result){case Result.Ok(ToolInvocationResult.Completed(_))=>actual.source.operationRoot
                        case _=>None}
                }else{None}
                case None=>None},
            knownParentGuard:if(outcome.knownParentPrepared.isSome() && outcome.attemptStage==OperationAttemptStage.Executing){
                match(outcome.result){case Result.Ok(ToolInvocationResult.Completed(_))=>Some({=>control.source.token.check()})
                    case _=>None}
            }else{None}
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (resolved.semanticCommit) {
            case Some(SemanticCommitDecision.Committed(_, _)) => Result.Ok(())
            case Some(SemanticCommitDecision.Stale(reason)) => Result.Err(AgentError(
                AgentErrorKind.Conflict, reason.code, reason.message
            ))
            case Some(SemanticCommitDecision.Rejected(error)) => Result.Err(error)
            case None => Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "operation.tool_result_missing",
                "terminal Operation did not commit a canonical ToolResult"
            ))
        }
    }

    // Session-level auto-retry is the sole production retry authority. Each
    // attempt is budgeted here; provider adapters perform one wire attempt.
    private func executeModelWithTurnRetry(
        request: AgentRunRequest,
        counter: BudgetCounter,
        modelRequest: ModelRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState
    ): Result<DurableModelResult> {
        let semanticRequestId = SemanticModelRequestId(
            "semantic-" + request.runId.value + "-model-" +
                (counter.modelRequests + 1).toString()
        )
        if (!request.autoRetry) {
            match (model.validatePolicySnapshot(request.model, Some(request.modelCapabilitiesSnapshot))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let attemptPlan = match (prepareModelAttemptRequest(
                request, modelRequest, semanticRequestId, 1,
                AttemptPolicyReason.Initial, control.recoveryPolicy180
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let effectiveAttemptRequest = attemptPlan.request
            let policy = attemptPlan.policy
            let attemptId = attemptPlan.attemptId
            match (persistModelAttemptBeforeRequest(
                request, semanticRequestId, attemptId, 1, None, policy, effectiveAttemptRequest,
                counter, context, control, sink, toolLoopState
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (reserveBudget(
                control,
                context,
                BudgetCharge(),
                sink,
                requestId: Some(RequestId(effectiveAttemptRequest.requestId))
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (reserveBudget(
                control,
                context,
                BudgetCharge(modelRequests: 1),
                sink,
                requestId: Some(RequestId(effectiveAttemptRequest.requestId))
            )) {
                case Result.Ok(_) =>
                    counter.recordModelRequest(control.budgetMode())
                case Result.Err(error) => return Result.Err(error)
            }
            match (claimModelAttemptBeforeRequest(
                attemptId, semanticRequestId, context, control, sink
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let dispatched = match (dispatchClaimedModelAttempt(
                request, counter, effectiveAttemptRequest, 1,
                semanticRequestId, attemptId, attemptPolicyReasonName(policy.reason),
                context, control, sink
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let execution = dispatched.execution
            let result = execution.result
            match (settleProvisionalModelEvents(
                execution.provisionalEvents, true, context, control,
                semanticRequestId, attemptId, sink
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let durable = durableResultForAttempt(
                request, semanticRequestId, attemptId, result
            )
            return recordDurableDecisionLifecycle(
                durable, context, control, semanticRequestId, attemptId, sink
            )
        }
        let maxAttempts: Int64 = 2
        var attempt: Int64 = 1
        var retried = false
        var retryOrigin: ?AgentError = None
        var recoveryCeiling: ?ThinkingLevel = None
        while (attempt <= maxAttempts) {
            let attemptReason = if (attempt == 1) {
                AttemptPolicyReason.Initial
            } else if (recoveryCeiling.isSome()) {
                AttemptPolicyReason.OutputLimitRecovery
            } else {
                AttemptPolicyReason.Retry
            }
            match (model.validatePolicySnapshot(request.model, Some(request.modelCapabilitiesSnapshot))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let attemptPlan = match (prepareModelAttemptRequest(
                request, modelRequest, semanticRequestId, attempt, attemptReason,
                control.recoveryPolicy180, recoveryCeiling: recoveryCeiling,
                parentAttemptId: if (attempt == 1) { None } else {
                    Some(modelAttemptIdFor(semanticRequestId, attempt - 1))
                }
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let policy = attemptPlan.policy
            let effectiveAttemptRequest = attemptPlan.request
            let attemptId = attemptPlan.attemptId
            match (persistModelAttemptBeforeRequest(
                request,
                semanticRequestId,
                attemptId,
                attempt,
                attemptPlan.parentAttemptId,
                policy,
                effectiveAttemptRequest,
                counter,
                context,
                control,
                sink,
                toolLoopState
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            // Each wire attempt (including retries) consumes the model request
            // budget so retries cannot bypass maxModelRequests.
            match (reserveBudget(
                control,
                context,
                BudgetCharge(),
                sink,
                requestId: Some(RequestId(effectiveAttemptRequest.requestId))
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (reserveBudget(
                control,
                context,
                BudgetCharge(modelRequests: 1),
                sink,
                requestId: Some(RequestId(effectiveAttemptRequest.requestId))
            )) {
                case Result.Ok(_) =>
                    counter.recordModelRequest(control.budgetMode())
                case Result.Err(error) => return Result.Err(error)
            }
            match (claimModelAttemptBeforeRequest(
                attemptId, semanticRequestId, context, control, sink
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let dispatched = match (dispatchClaimedModelAttempt(
                request, counter, effectiveAttemptRequest, attempt,
                semanticRequestId, attemptId, attemptPolicyReasonName(policy.reason),
                context, control, sink, settleOnRecordFailure: true
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let execution = dispatched.execution
            let result = execution.result
            let provisionalEvents = execution.provisionalEvents
            let durableResult = durableResultForAttempt(
                request, semanticRequestId, attemptId, result,
                terminalizeFailure: false
            )
            match (durableResult) {
                case Result.Ok(durableValue) =>
                    match (settleProvisionalModelEvents(
                        provisionalEvents, true, context, control,
                        semanticRequestId, attemptId, sink
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
                    if (retried) {
                        let _ = emitDetail(
                            context,
                            AgentEventKind.Diagnostic,
                            objectValue(
                                [
                                    ValueField("code", textValue("model.auto_retry_end")),
                                    ValueField("success", boolValue(true)),
                                    ValueField("attempts", integerValue(attempt))
                                ]
                            ),
                            sink
                        )
                    }
                    return recordDurableDecisionLifecycle(
                        Result.Ok(durableValue), context, control,
                        semanticRequestId, attemptId, sink
                    )
                case Result.Err(error) =>
                    if (retryOrigin.isNone()) { retryOrigin = Some(error) }
                    if (control.source.token.isCancelled() ||
                        isRunCancelled(request.runId)) {
                        let cancelled = controlCancellationError(control)
                        let _ = modelDecisionRuntime.terminalizeAttempt(
                            attemptId, ModelAttemptLifecycle.Cancelled,
                            attemptFailureKindName(AttemptFailureKind.UserCancelled),
                            agentUtcMillis()
                        )
                        let _ = emitAttemptLifecycle(
                            context, control, semanticRequestId, attemptId,
                            "model.attempt_cancelled", sink
                        )
                        if (retried) {
                            let _ = emitDetail(
                                context,
                                AgentEventKind.Diagnostic,
                                objectValue(
                                    [
                                        ValueField("code", textValue("model.auto_retry_end")),
                                        ValueField("success", boolValue(false)),
                                        ValueField("attempts", integerValue(attempt)),
                                        ValueField("error_code", textValue(cancelled.code))
                                    ]
                                ),
                                sink
                            )
                        }
                        match (settleProvisionalModelEvents(
                            provisionalEvents, true, context, control,
                            semanticRequestId, attemptId, sink
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(settleError) => return Result.Err(settleError)
                        }
                        return Result.Err(cancelled)
                    }
                    let durable = match (modelDecisionRuntime.uncommittedDecision(
                        request.runId
                    )) {
                        case Result.Ok(value) => value
                        case Result.Err(storeError) =>
                            match (settleProvisionalModelEvents(
                                provisionalEvents, true, context, control,
                                semanticRequestId, attemptId, sink
                            )) {
                                case Result.Ok(_) => return Result.Err(storeError)
                                case Result.Err(settleError) => return Result.Err(settleError)
                            }
                    }
                    let persistedAttempt = match (runs.modelAttempt(attemptId)) {
                        case Result.Ok(value) => value
                        case Result.Err(storeError) =>
                            match (settleProvisionalModelEvents(
                                provisionalEvents, true, context, control,
                                semanticRequestId, attemptId, sink
                            )) {
                                case Result.Ok(_) => return Result.Err(storeError)
                                case Result.Err(settleError) => return Result.Err(settleError)
                            }
                            return Result.Err(storeError)
                    }
                    let durableMayWin = durable.isSome() &&
                        persistedAttempt.replayBarrier != ModelAttemptReplayBarrier.Cancelled &&
                        persistedAttempt.replayBarrier != ModelAttemptReplayBarrier.RunDeadline
                    let failurePlan = planModelAttemptFailure(
                        error, durableMayWin, persistedAttempt.replayBarrier,
                        attempt, maxAttempts, control.recoveryPolicy180.maxRecoveryRetries
                    )
                    let disposition = failurePlan.disposition
                    match (disposition) {
                        case AttemptRetryDisposition.ResumeDurableDecision =>
                            let decision = durable.getOrThrow()
                            if (decision.attemptId.value != attemptId.value ||
                                decision.semanticRequestId.value != semanticRequestId.value) {
                                let bindingError = AgentError(
                                    AgentErrorKind.RecoveryRequired,
                                    "model.decision_attempt_binding_invalid",
                                    "durable Model Decision does not match the active attempt"
                                )
                                match (settleProvisionalModelEvents(
                                    provisionalEvents, true, context, control,
                                    semanticRequestId, attemptId, sink
                                )) {
                                    case Result.Ok(_) => return Result.Err(bindingError)
                                    case Result.Err(settleError) => return Result.Err(settleError)
                                }
                            }
                            match (settleProvisionalModelEvents(
                                provisionalEvents, true, context, control,
                                semanticRequestId, attemptId, sink
                            )) {
                                case Result.Ok(_) => ()
                                case Result.Err(settleError) => return Result.Err(settleError)
                            }
                            return Result.Ok(recoveredDurableModelResult(
                                decision
                            ))
                        case _ => ()
                    }
                    let outputLimitedRecovery = failurePlan.outputLimited
                    let willRetry = failurePlan.willRetry
                    match (settleProvisionalModelEvents(
                        provisionalEvents, !willRetry, context, control,
                        semanticRequestId, attemptId, sink
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(settleError) => return Result.Err(settleError)
                    }
                    match (modelDecisionRuntime.terminalizeAttempt(
                        attemptId,
                        if (willRetry) {
                            ModelAttemptLifecycle.Abandoned
                        } else { ModelAttemptLifecycle.Failed },
                        match (error.attemptFailure) {
                            case Some(value) => attemptFailureKindName(value.kind)
                            case None => error.code
                        },
                        agentUtcMillis()
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(storeError) => return Result.Err(storeError)
                    }
                    if (willRetry) {
                        let _ = emitAttemptLifecycle(
                            context, control, semanticRequestId, attemptId,
                            "model.attempt_aborted", sink,
                            fields: [ValueField("error_code", textValue(error.code))]
                        )
                        let _ = emitDetail(
                            context,
                            AgentEventKind.Diagnostic,
                            objectValue([
                                ValueField("code", textValue("model.attempt_abandoned")),
                                ValueField("attempt", integerValue(attempt)),
                                ValueField("error_code", textValue(error.code))
                            ]),
                            sink
                        )
                    }
                    if (!willRetry) {
                        let _ = emitAttemptLifecycle(
                            context, control, semanticRequestId, attemptId,
                            "model.attempt_failed", sink,
                            fields: [ValueField("error_code", textValue(error.code))]
                        )
                    }
                    if (!willRetry) {
                        let terminalError = if (outputLimitedRecovery) {
                            outputLimitedExhaustedError(
                                error, attempt, effectiveAttemptRequest, attemptId
                            )
                        } else { representativeModelRetryError(retryOrigin, error) }
                        if (retried) {
                            let _ = emitDetail(
                                context,
                                AgentEventKind.Diagnostic,
                                objectValue(
                                    [
                                        ValueField("code", textValue("model.auto_retry_end")),
                                        ValueField("success", boolValue(false)),
                                        ValueField("attempts", integerValue(attempt)),
                                        ValueField("error_code", textValue(terminalError.code))
                                    ]
                                ),
                                sink
                            )
                        }
                        return Result.Err(terminalError)
                    }
                    retried = true
                    if (disposition == AttemptRetryDisposition.RetryEscalated) {
                        let effectiveThinking = match (effectiveAttemptRequest.resolvedPolicy) {
                            case Some(value) => value.thinking.effective
                            case None => effectiveAttemptRequest.thinking
                        }
                        recoveryCeiling = nextLowerThinkingCeiling(
                            request.modelCapabilitiesSnapshot,
                            effectiveThinking
                        )
                        if (recoveryCeiling.isNone()) {
                            return Result.Err(outputLimitedExhaustedError(
                                error, attempt, effectiveAttemptRequest, attemptId
                            ))
                        }
                    }
                    let _ = emitAttemptLifecycle(
                        context, control, semanticRequestId, attemptId,
                        "model.attempt_retry_scheduled", sink,
                        fields: [ValueField("next_attempt_no", integerValue(attempt + 1))]
                    )
                    let _ = emitDetail(
                        context,
                        AgentEventKind.Diagnostic,
                        objectValue(
                            [
                                ValueField("code", textValue("model.auto_retry_start")),
                                ValueField("attempt", integerValue(attempt)),
                                ValueField("max_attempts", integerValue(maxAttempts)),
                                ValueField("error_code", textValue(error.code)),
                                ValueField("policy_reason", textValue(
                                    if (disposition == AttemptRetryDisposition.RetryEscalated) {
                                        "deadline_escalation"
                                    } else { "retry" }
                                ))
                            ]
                        ),
                        sink
                    )
                    match (waitForRetryDelay(
                        request,
                        counter,
                        control,
                        retryDelayMillis(attempt, error)
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(waitError) =>
                            let _ = emitDetail(
                                context,
                                AgentEventKind.Diagnostic,
                                objectValue(
                                    [
                                        ValueField("code", textValue("model.auto_retry_end")),
                                        ValueField("success", boolValue(false)),
                                        ValueField("attempts", integerValue(attempt)),
                                        ValueField("error_code", textValue(waitError.code))
                                    ]
                                ),
                                sink
                            )
                            return Result.Err(waitError)
                    }
            }
            attempt += 1
        }
        Result.Err(
            AgentError(
                AgentErrorKind.Internal,
                "model.turn_retry_exhausted",
                "model turn retry loop exhausted without a result"
            )
        )
    }

    private func recordModelAttempt(
        request: AgentRunRequest,
        modelRequest: ModelRequest,
        attempt: Int64,
        counter: BudgetCounter,
        result: Result<ModelReply>,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        var budgetFailure: ?AgentError = None
        let value = match (result) {
            case Result.Ok(reply) => ModelRequestAttempt(
                RequestId(modelRequest.requestId),
                modelRequest.model,
                attempt,
                ModelRequestOutcome.Succeeded,
                usage: Some(accountedModelAttemptUsage(
                    reply,
                    request.pricing
                ))
            )
            case Result.Err(error) =>
                // A provider may bill a request whose reply was rejected
                // (malformed tool arguments) or whose stream died before a
                // terminal (truncated stream). The adapter surfaces that
                // observed usage as error fields; charge it so cumulative
                // token and cost enforcement counts abandoned attempts too.
                let billed = attemptUsageFromError(error, request.pricing)
                match (billed) {
                    case Some(usage) =>
                        match (counter.accountAttemptUsage(usage, request.budget)) {
                            case Result.Err(requestBudgetError) =>
                                // Provider-reported usage is irreversible even
                                // when it violates the per-request ceiling.
                                let _ = control.ledger.recordObservedUsage(usage)
                                budgetFailure = Some(requestBudgetError)
                            case Result.Ok(_) => match (reserveBudget(
                                control,
                                context,
                                BudgetCharge(
                                    inputTokens: usage.inputTokens,
                                    outputTokens: usage.outputTokens,
                                    costMicros: match (usage.costMicros) {
                                        case Some(value) => value
                                        case None => 0
                                    }
                                ),
                                sink,
                                requestId: Some(RequestId(modelRequest.requestId)),
                                observedUsage: Some(usage)
                            )) {
                                case Result.Ok(_) => ()
                                case Result.Err(budgetError) =>
                                    budgetFailure = Some(budgetError)
                            }
                        }
                    case None => ()
                }
                ModelRequestAttempt(
                    RequestId(modelRequest.requestId),
                    modelRequest.model,
                    attempt,
                    if (error.kind == AgentErrorKind.Cancelled) {
                        ModelRequestOutcome.Cancelled
                    } else {
                        ModelRequestOutcome.Failed
                    },
                    usage: billed,
                    errorCode: error.code
                )
        }
        match (emitTyped(
            context,
            control,
            AgentEventPayload.ModelRequestAttemptCompleted(value),
            sink,
            requestId: Some(value.requestId)
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => match (budgetFailure) {
                case Some(error) => Result.Err(error)
                case None => Result.Ok(())
            }
        }
    }

    private func retryDelayMillis(attempt: Int64, error: AgentError): Int64 {
        let serverDelay = match (retryAfterMillisField(error)) {
            case Some(value) => try {
                Int64.parse(value)
            } catch (_: Exception) {
                0
            }
            case None => 0
        }
        if (serverDelay > 0) {
            return min(serverDelay, MODEL_RETRY_MAX_DELAY_MILLIS)
        }
        let backoff = 500 * (1 << (attempt - 1))
        min(backoff, MODEL_RETRY_MAX_DELAY_MILLIS)
    }

    private func waitForRetryDelay(
        request: AgentRunRequest,
        counter: BudgetCounter,
        control: CoreRunControl,
        delayMillis: Int64
    ): Result<Unit> {
        let boundedDelay = min(
            max(0, delayMillis),
            MODEL_RETRY_MAX_DELAY_MILLIS
        )
        let started = MonoTime.now()
        while (true) {
            match (control.ledger.reserve(BudgetCharge())) {
                case Result.Err(error) =>
                    let _ = control.requestCancel(
                        CancellationReasonKind.Budget,
                        error.code,
                        error.message
                    )
                    return Result.Err(error)
                case Result.Ok(_) => ()
            }
            if (control.source.token.isCancelled() ||
                isRunCancelled(request.runId)) {
                return Result.Err(controlCancellationError(control))
            }
            if (request.budget.maxWallMillis > 0 &&
                (MonoTime.now() - counter.startedAt).toMilliseconds() >=
                request.budget.maxWallMillis) {
                return Result.Err(modelTimeoutError(
                    "wall",
                    request.budget.maxWallMillis
                ))
            }
            let elapsed = (MonoTime.now() - started).toMilliseconds()
            if (elapsed >= boundedDelay) {
                return Result.Ok(())
            }
            sleep(Duration.millisecond * min(
                MODEL_RETRY_POLL_MILLIS,
                boundedDelay - elapsed
            ))
        }
        Result.Ok(())
    }

    private func dispatchClaimedModelAttempt(
        request: AgentRunRequest,
        counter: BudgetCounter,
        modelRequest: ModelRequest,
        attemptNo: Int64,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        policyReasonName: String,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        settleOnRecordFailure!: Bool = false
    ): Result<ModelAttemptDispatch> {
        let _ = emitAttemptLifecycle(
            context, control, semanticRequestId, attemptId,
            "model.attempt_started", sink,
            fields: [
                ValueField("attempt_no", integerValue(attemptNo)),
                ValueField("policy_reason", textValue(policyReasonName))
            ]
        )
        let startedAt = MonoTime.now()
        let execution = executeModelWithinBudget(
            request, counter, modelRequest, semanticRequestId,
            attemptId, context, control, sink
        )
        control.collectReturnedModelInputs159()
        match (recordModelAttempt(
            request, modelRequest, attemptNo, counter, execution.result,
            context, control, sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                if (settleOnRecordFailure) {
                    match (settleProvisionalModelEvents(
                        execution.provisionalEvents, true, context, control,
                        semanticRequestId, attemptId, sink
                    )) {
                        case Result.Ok(_) => return Result.Err(error)
                        case Result.Err(settleError) => return Result.Err(settleError)
                    }
                }
                return Result.Err(error)
        }
        match (persistDeferredModelAttemptBarrier(
            execution, attemptId, semanticRequestId, context, control, sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(ModelAttemptDispatch(execution, startedAt))
    }

    private func executeModelWithinBudget(
        request: AgentRunRequest,
        counter: BudgetCounter,
        modelRequest: ModelRequest,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): ModelAttemptExecution {
        let inputCustody159 = match (catalog.reserveModelInputData159(modelRequest, settings180: Some(request.toolContext))) {
            case Some(payment) =>
                let value = CoreModelInput159(payment, modelRequest)
                control.retainModelInput159(value)
                Some(value)
            case None => None<CoreModelInput159>
        }
        try {
            let result = executeModelWithinBudgetBody159(request, counter, modelRequest,
                semanticRequestId, attemptId, context, control, sink, inputCustody159)
            // The complete original caller frame, including its local Future,
            // returned before this scalar marker. Collection happens outside
            // this wrapper; marking alone never clears or refunds anything.
            match (inputCustody159) { case Some(value) => value.returnedCaller159(); case None => () }
            result
        } catch (error: Exception) {
            match (inputCustody159) { case Some(value) => value.hold159(); value.returnedCaller159(); case None => () }
            throw error
        }
    }

    private func executeModelWithinBudgetBody159(
        request: AgentRunRequest,
        counter: BudgetCounter,
        modelRequest: ModelRequest,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        inputCustody159: ?CoreModelInput159
    ): ModelAttemptExecution {
        let activity = AttemptDeadlineContext(
            control.recoveryPolicy180, attemptClock,
            idleLimitMillis: request.budget.maxIdleMillis
        )
        control.setActiveRequest(modelRequest.requestId)
        let admitted = AtomicInt64(0)
        let completed = AtomicBool(false)
        let modelAction159 = { =>
            while (admitted.load() == 0) { sleep(Duration.millisecond) }
            try {
                if (admitted.load() < 0 || control.source.token.isCancelled()) {
                    return Result<ModelReply>.Err(controlCancellationError(control))
                }
                match (validateContextSnapshotUse(request.contextSnapshot)) {
                    case Result.Err(error) => return Result<ModelReply>.Err(error); case Result.Ok(_) => () }
                executeModelInput159(model,
                modelRequest,
                {
                    event => if (activity.record(event)) {
                        match (modelEventImmediateReplayBarrier(event)) {
                            case Some(barrier) => match (persistFirstModelAttemptBarrier(
                                activity, attemptId, semanticRequestId, barrier,
                                context, control, sink
                            )) {
                                case Result.Ok(_) => ()
                                case Result.Err(error) =>
                                    activity.recordPersistenceFailure(error)
                            }
                            case None => ()
                        }
                        if (activity.persistenceError().isNone()) {
                            match (forwardModelEvent(
                                context, control, semanticRequestId, attemptId, event, sink
                            )) {
                                case Result.Ok(_) => ()
                                case Result.Err(error) =>
                                    activity.recordPersistenceFailure(error)
                            }
                        }
                    }
                }, inputCustody159, request.toolContext.executionSettings180, request.toolContext.modelFaultCounters180,
                { => control.source.token.isCancelled() || !activity.acceptsEvents180() }
            )
            } finally { completed.store(true) }
        }
        let future = match (inputCustody159) {
            case Some(value) => value.start159(modelAction159)
            case None => spawn { modelAction159() }
        }
        let owned = spawn { let _ = future.get() }
        match (control.runtime.ownTask("model/" + attemptId.value, owned)) {
            case Result.Ok(_) => admitted.store(1)
            case Result.Err(error) =>
                admitted.store(-1)
                activity.close()
                control.clearActiveRequest(modelRequest.requestId)
                return ModelAttemptExecution(Result.Err(error), activity.takeProvisionalOutput())
        }
        while (!completed.load()) {
            match (activity.persistenceError()) {
                case Some(error) =>
                    activity.close()
                    let _ = model.cancel(modelRequest.requestId)
                    control.clearActiveRequest(modelRequest.requestId)
                    return ModelAttemptExecution(
                        Result.Err(error), activity.takeProvisionalOutput()
                    )
                case None => ()
            }
            match (control.ledger.reserve(BudgetCharge())) {
                case Result.Err(error) =>
                    activity.close()
                    match (persistFirstModelAttemptBarrier(
                        activity, attemptId, semanticRequestId,
                        ModelAttemptReplayBarrier.Cancelled,
                        context, control, sink
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(storeError) => return ModelAttemptExecution(
                            Result.Err(storeError), activity.takeProvisionalOutput()
                        )
                    }
                    let _ = control.requestCancel(
                        CancellationReasonKind.Budget,
                        error.code,
                        error.message
                    )
                    control.clearActiveRequest(modelRequest.requestId)
                    return ModelAttemptExecution(
                        Result.Err(error), activity.takeProvisionalOutput()
                    )
                case Result.Ok(_) => ()
            }
            if (control.source.token.isCancelled() || isRunCancelled(request.runId)) {
                activity.close()
                match (persistFirstModelAttemptBarrier(
                    activity, attemptId, semanticRequestId,
                    if (request.budget.deadlineMillis > 0 &&
                        agentUtcMillis() >= request.budget.deadlineMillis) {
                        ModelAttemptReplayBarrier.RunDeadline
                    } else { ModelAttemptReplayBarrier.Cancelled },
                    context, control, sink
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(storeError) => return ModelAttemptExecution(
                        Result.Err(storeError), activity.takeProvisionalOutput()
                    )
                }
                let _ = model.cancel(modelRequest.requestId)
                control.clearActiveRequest(modelRequest.requestId)
                return ModelAttemptExecution(
                    Result.Err(controlCancellationError(control)),
                    activity.takeProvisionalOutput()
                )
            }
            if (request.budget.maxWallMillis > 0 &&
                (MonoTime.now() - counter.startedAt).toMilliseconds() >=
                request.budget.maxWallMillis) {
                activity.close()
                match (persistFirstModelAttemptBarrier(
                    activity, attemptId, semanticRequestId,
                    ModelAttemptReplayBarrier.RunDeadline,
                    context, control, sink
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(storeError) => return ModelAttemptExecution(
                        Result.Err(storeError), activity.takeProvisionalOutput()
                    )
                }
                let _ = model.cancel(modelRequest.requestId)
                control.clearActiveRequest(modelRequest.requestId)
                    return ModelAttemptExecution(
                        Result.Err(modelTimeoutError(
                            "wall",
                            request.budget.maxWallMillis
                        )), activity.takeProvisionalOutput()
                    )
            }
            match (activity.evaluate()) {
                    case AttemptDeadlineAction.Continue => ()
                    case AttemptDeadlineAction.EnterDecisionCompletionGrace =>
                        let diagnostic = activity.diagnostics()
                        let _ = emitDetail(
                            context, AgentEventKind.Diagnostic,
                            objectValue([
                                ValueField("code", textValue(
                                    "model.decision_completion_grace_entered"
                                )),
                                ValueField("elapsed_ms", integerValue(diagnostic.elapsedMillis)),
                                ValueField("soft_deadline_ms", integerValue(
                                    diagnostic.softDeadlineMillis
                                )),
                                ValueField("hard_deadline_ms", integerValue(
                                    diagnostic.hardDeadlineMillis
                                )),
                                ValueField("last_progress_kind", textValue(
                                    attemptProgressKindName(diagnostic.lastProgressKind)
                                )),
                                ValueField("last_progress_age_ms", integerValue(
                                    diagnostic.lastProgressAgeMillis
                                ))
                            ]), sink,
                            semanticRequestId: Some(semanticRequestId),
                            attemptId: Some(attemptId)
                        )
                    case AttemptDeadlineAction.StreamIdle =>
                        activity.close()
                        let _ = model.cancel(modelRequest.requestId)
                        control.clearActiveRequest(modelRequest.requestId)
                        return ModelAttemptExecution(
                            Result.Err(attemptFailureError(
                                AttemptFailureKind.StreamIdleTimeout,
                                "model.stream_idle_timeout",
                                "model stream made no meaningful progress before the idle deadline",
                                activity.diagnostics(), retryable: true
                            )), activity.takeProvisionalOutput()
                        )
                    case AttemptDeadlineAction.SoftDeadlineExceeded =>
                        activity.close()
                        let _ = model.cancel(modelRequest.requestId)
                        control.clearActiveRequest(modelRequest.requestId)
                        return ModelAttemptExecution(
                            Result.Err(attemptFailureError(
                                AttemptFailureKind.AttemptSoftDeadlineExceeded,
                                "model.attempt_soft_deadline_exceeded",
                                "model attempt reached its soft deadline without completion progress",
                                activity.diagnostics(), retryable: true
                            )), activity.takeProvisionalOutput()
                        )
                    case AttemptDeadlineAction.HardDeadlineExceeded =>
                        activity.close()
                        let _ = model.cancel(modelRequest.requestId)
                        control.clearActiveRequest(modelRequest.requestId)
                        return ModelAttemptExecution(
                            Result.Err(attemptFailureError(
                                AttemptFailureKind.AttemptHardDeadlineExceeded,
                                "model.attempt_hard_deadline_exceeded",
                                "model attempt exceeded its immutable hard deadline",
                                activity.diagnostics(), retryable: true
                            )), activity.takeProvisionalOutput()
                        )
                    case AttemptDeadlineAction.ReasoningRestartedInGrace =>
                        activity.close()
                        let _ = model.cancel(modelRequest.requestId)
                        control.clearActiveRequest(modelRequest.requestId)
                        return ModelAttemptExecution(
                            Result.Err(attemptFailureError(
                                AttemptFailureKind.DecisionIncompleteAtDeadline,
                                "model.grace_reasoning_restarted",
                                "model restarted reasoning after entering decision completion grace",
                                activity.diagnostics(), retryable: true
                            )), activity.takeProvisionalOutput()
                        )
            }
            sleep(Duration.millisecond * 10)
        }
        activity.close()
        let result = future.get()
        control.clearActiveRequest(modelRequest.requestId)
        let completionCancellationBarrier: ?ModelAttemptReplayBarrier = if (
            control.source.token.isCancelled() || isRunCancelled(request.runId) ||
            match (result) {
                case Result.Err(error) => error.kind == AgentErrorKind.Cancelled
                case Result.Ok(_) => false
            }
        ) {
            Some(if (request.budget.deadlineMillis > 0 &&
                agentUtcMillis() >= request.budget.deadlineMillis) {
                ModelAttemptReplayBarrier.RunDeadline
            } else {
                ModelAttemptReplayBarrier.Cancelled
            })
        } else { None }
        match (completionCancellationBarrier) {
            case Some(barrier) => match (persistFirstModelAttemptBarrier(
                activity, attemptId, semanticRequestId, barrier,
                context, control, sink
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return ModelAttemptExecution(
                    Result.Err(error), activity.takeProvisionalOutput()
                )
            }
            case None => ()
        }
        match (activity.persistenceError()) {
            case Some(error) => return ModelAttemptExecution(
                Result.Err(error), activity.takeProvisionalOutput()
            )
            case None => ()
        }
        let provisionalEvents = activity.takeProvisionalOutput()
        let observedBarrier = activity.observedReplayBarrier()
        match (result) {
            case Result.Err(error) =>
                // Partial deltas stay attempt-scoped and diagnostic-only. The
                // first ToolCall observation is nevertheless a durable replay
                // barrier, so the retry resolver will reject replay even when
                // the provider later returns a retryable transport failure.
                let partial = activity.hasEvents()
                let execution = if (error.retryable && partial) {
                    let fields = ArrayList<ErrorField>()
                    for (field in error.fields where field.name != "partial_stream") {
                        fields.add(field)
                    }
                    fields.add(ErrorField("partial_stream", "true"))
                    ModelAttemptExecution(
                        Result.Err(AgentError(
                            error.kind,
                            error.code,
                            error.message,
                            retryable: true,
                            fallbackAllowed: error.fallbackAllowed,
                            fields: fields.toArray(),
                            attemptFailure: error.attemptFailure, observation: error.observation
                        )), provisionalEvents
                    )
                } else {
                    ModelAttemptExecution(Result.Err(error), provisionalEvents)
                }
                execution.replayBarrier = observedBarrier
                execution
            case Result.Ok(reply) =>
                let execution = ModelAttemptExecution(
                    Result.Ok(reply), provisionalEvents
                )
                execution.replayBarrier = if (
                    observedBarrier == ModelAttemptReplayBarrier.NoBarrier
                ) {
                    ModelAttemptReplayBarrier.ProviderTerminal
                } else { observedBarrier }
                execution
        }
    }

    private func settleProvisionalModelEvents(
        events: Array<ModelEvent>,
        keep: Bool,
        context: ToolInvocationContext,
        control: CoreRunControl,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        sink: AgentEventSink
    ): Result<Unit> {
        // Text/reasoning deltas are persisted as bounded stream telemetry and
        // delivered live from the provider callback. Replaying them here
        // would duplicate every successful delta in the live sink. The
        // arguments remain in the private execution record only for source
        // compatibility with the retry state machine.
        let _ = events
        let _ = keep
        let _ = context
        let _ = control
        let _ = semanticRequestId
        let _ = attemptId
        let _ = sink
        Result.Ok(())
    }

    private func isRunCancelled(runId: RunId): Bool {
        match (runs.find(runId)) {
            case Result.Ok(snapshot) => snapshot.status == RunState.Cancelled || snapshot.status == RunState
                .Cancelling
            case Result.Err(_) => false
        }
    }

    private func cancelledRun(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        counter!: ?BudgetCounter = None
    ): Result<AgentRunOutcome> {
        fail(
            request,
            context,
            control,
            AgentError(
                AgentErrorKind.Cancelled,
                "run.cancelled",
                "agent run was cancelled"
            ),
            sink,
            counter: counter
        )
    }

    private func injectSteering(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        sink: AgentEventSink
    ): Result<Bool> {
        match (request.interactions) {
            case Some(source) => appendQueuedInputs(
                source.takeSteering(),
                context,
                sink
            )
            case None => Result.Ok(false)
        }
    }

    private func injectFollowUps(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        sink: AgentEventSink
    ): Result<Bool> {
        match (request.interactions) {
            case Some(source) => appendQueuedInputs(
                source.takeFollowUps(),
                context,
                sink
            )
            case None => Result.Ok(false)
        }
    }

    private func appendQueuedInputs(
        values: Array<AgentQueuedInput>,
        context: ToolInvocationContext,
        sink: AgentEventSink
    ): Result<Bool> {
        if (values.isEmpty()) {
            return Result.Ok(false)
        }
        let control = match (controls.find(context.runId)) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "interaction.run_owner_missing",
                "queued input has no active canonical Run owner"
            ))
        }
        for (value in values) {
            let thread = coreOwnedControlMetadata(control.runtime)
            match (control.runtime.appendUserInput(
                ItemId(if (value.durableItemId != "") {
                    value.durableItemId
                } else if (value.correlationId != "") {
                    "interaction-" + value.correlationId
                } else {
                    "interaction-" + context.runId.value + "-" +
                        thread.nextResultSequence.toString()
                }),
                ThreadItemContent.UserMessage(textMessageParts(value.text)),
                ItemProvenance("interaction", runId: Some(context.runId)),
                agentUtcMillis()
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (emitDetail(
                context,
                AgentEventKind.Transcript,
                objectValue(
                    [
                        ValueField(
                            "code",
                            textValue("interaction.injected")
                        ),
                        ValueField(
                            "correlation_id",
                            textValue(value.correlationId)
                        ),
                        ValueField("kind", textValue(value.kind)),
                        ValueField("text", textValue(value.text))
                    ]
                ),
                sink
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(true)
    }

    private func hasSteering(request: AgentRunRequest): Bool {
        match (request.interactions) {
            case Some(source) => source.hasSteering()
            case None => false
        }
    }

    private func interruptsImmediately(request: AgentRunRequest): Bool {
        match (request.interactions) {
            case Some(source) => match (source.interruptMode()) {
                case RunInterruptMode.Immediate => true
                case RunInterruptMode.Wait => false
            }
            case None => false
        }
    }

    private func appendSkippedToolCall(
        sessionId: SessionId,
        context: ToolInvocationContext,
        control: CoreRunControl,
        committed: CommittedToolCallRef,
        sink: AgentEventSink,
        errorCode!: String = "tool.skipped_for_steering",
        message!: String = "tool was skipped because a steering message is pending",
        cancellationSettlement!: Bool = false
    ): Result<Unit> {
        let block = committed.block
        let output = objectValue(
            [
                ValueField(
                    "error",
                    textValue(errorCode)
                ),
                ValueField(
                    "message",
                    textValue(message)
                )
            ]
        )
        let operationId = OperationId(
            "operation-skipped-" + committed.decisionId.value + "-" +
                committed.scopedToolCallId.value
        )
        let plan = if (cancellationSettlement) {
            // No descriptor, resolver, preflight, policy or executor runs here.
            // The durable port only admits a zero-authority rejection fact.
            if (!control.source.token.isCancelled() ||
                errorCode != "tool.cancelled_during_preparation" ||
                canonicalAgentValue(output) != canonicalAgentValue(cancelledUnpreparedToolOutput())) {
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "operation.cancellation_settlement_invalid", "cancellation settlement is not an ordinary skip"))
            }
            match (operationRuntime.prepareCancellationSettlement(operationId, context.runId, committed, context.epoch)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
            }
        } else {
            let value = canonicalImmediatePlan(context, block)
            match (operationRuntime.prepare(operationId, context.runId, committed, value)) {
                case Result.Ok(_) => (); case Result.Err(error) => return Result.Err(error)
            }
            value
        }
        match (commitCanonicalToolAttempt(
            control,
            CoreToolOutcome(
                0,
                committed,
                Result.Ok(ToolInvocationResult.Completed(ToolResult(
                    block.callId, output, isError: true
                ))),
                operationId: Some(operationId),
                operationPlan: Some(plan),
                attemptStage: OperationAttemptStage.Prepared
            )
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (emitDetail(
            context,
            AgentEventKind.Tool,
            objectValue(
                [
                    ValueField(
                        "code",
                        textValue("tool.execution_skipped")
                    ),
                    ValueField("name", textValue(block.name)),
                    ValueField("call_id", textValue(block.callId)),
                    ValueField("output", output),
                    ValueField("is_error", boolValue(true)),
                    ValueField("receipt_id", textValue(""))
                ]
            ),
            sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let _ = sessionId
        Result.Ok(())
    }

    private func pendingCommittedToolCalls(
        control: CoreRunControl
    ): Result<Array<CommittedToolCallRef>> {
        let snapshot = control.runtime.threadSnapshot()
        let activeTurnId = match (snapshot.thread.activeTurnId) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "thread.no_active_turn",
                "pending ToolCalls require an active canonical Turn"
            ))
        }
        let pendingIds = HashSet<String>()
        let completed = HashSet<String>()
        for (item in snapshot.items where item.turnId.value == activeTurnId.value) {
            match (item.content) {
                case ThreadItemContent.ToolCall(callId, _, _) => pendingIds.add(callId.value)
                case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                    completed.add(callId.value)
                case _ => ()
            }
        }
        let sources = match (modelDecisionRuntime.committedToolCallSources(control.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let pendingSources = ArrayList<CommittedToolCallSource>()
        for (source in sources where pendingIds.contains(source.block.callId) &&
            !completed.contains(source.block.callId)) {
            pendingSources.add(source)
        }
        control.runtime.attestCommittedToolCalls(pendingSources.toArray())
    }

    private func committedToolCallFor(
        control: CoreRunControl,
        providerCallId: String
    ): Result<CommittedToolCallRef> {
        let calls = match (pendingCommittedToolCalls(control)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (call in calls where call.block.callId == providerCallId) {
            return Result.Ok(call)
        }
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.committed_tool_call_missing",
            "canonical ToolCall has no validated durable Decision source",
            fields: [ErrorField("call_id", providerCallId)]
        ))
    }

    private func completeRecoveredDecision(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        counter: BudgetCounter,
        decision: ModelDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let completed = RunSnapshot(
            request.runId, request.sessionId, RunState.Completed,
            sequence: context.currentSequence(),
            summary: "recovered durable Model Decision " + decision.id.value,
            modelRequests: counter.modelRequests,
            usage: counter.usage(),
            lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens,
            lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls,
            turns: counter.turns
        )
        let transition = match (control.finish(
            RunState.Completed, reason: "recovered durable decision committed"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (transition.to != RunState.Completed) {
            return fail(request, context, control,
                AgentError(AgentErrorKind.RecoveryRequired, "run.owned_work_unsettled",
                    "owned work prevented successful Run settlement"),
                sink, counter: Some(counter))
        }
        match (runs.save(completed)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let _ = emitTransition(context, control, transition, sink)
        let _ = emitTyped(context, control, AgentEventPayload.RunCompleted, sink)
        finishControl(request.runId)
        Result.Ok(AgentRunOutcome.Completed(completed))
    }

    private func emitDetail(
        context: ToolInvocationContext,
        kind: AgentEventKind,
        detail: AgentValue,
        sink: AgentEventSink,
        semanticRequestId!: ?SemanticModelRequestId = None,
        attemptId!: ?ModelAttemptId = None
    ): Result<Unit> {
        match (controls.find(context.runId)) {
            case Some(control) => return emitExtension(
                context,
                control,
                kind,
                detail,
                sink,
                semanticRequestId: semanticRequestId,
                attemptId: attemptId
            )
            case None => ()
        }
        let event = AgentEvent(
            EventMeta(
                context.nextSequence(),
                TraceId("core-" + context.runId.value),
                context.runId,
                occurredAtMillis: agentUtcMillis(),
                semanticRequestId: semanticRequestId,
                attemptId: attemptId
            ),
            AgentEventPayload.Extension(kind, detail)
        )
        match (runs.append(event)) {
            case Result.Ok(_) =>
                sink(event)
                Result.Ok(())
            case Result.Err(error) =>
                // Stream telemetry is provisional observability. Its durable
                // write must never invalidate a durable Decision or trigger a
                // second model Attempt; live delivery remains best effort.
                if (isProvisionalStreamTelemetry(event)) {
                    sink(event)
                    Result.Ok(())
                } else { Result.Err(error) }
        }
    }

    private func emitOwnedCanonicalToolStarted(context: ToolInvocationContext, control: CoreRunControl,
        committed: CommittedToolCallRef, batch: ToolBatchId, sink: OwnedAgentEventSink): Result<Unit> {
        let repository = match (runs as OwnedRunEventRepository) {
            case Some(actual) => actual
            case None => return coreOwnedCanonicalDeliveryError("tool.canonical_start_repository_missing") }
        let reader = match (control.runtime.ownedCanonicalReadback()) {
            case Some(actual) => actual
            case None => return coreOwnedCanonicalDeliveryError("tool.canonical_start_reader_missing") }
        let metadata = control.runtime.threadMetadataSnapshot()
        if (metadata.thread.id.value != context.sessionId.value || metadata.activeRunId.isNone() ||
            metadata.activeRunId.getOrThrow().value != context.runId.value || metadata.activeEpoch != context.epoch) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_start_scope_changed") }
        let guard: () -> Result<Unit> = { => context.cancellation.check() }
        let read = CoreOwnedToolCallItemRead(reader, metadata.thread.id, metadata.thread.revision,
            committed.canonicalItemId)
        // Preserve the original event sequence/meta and append-before-observer
        // order. All full-cell aliases retire before fixed-TEXT append; fresh
        // paid readback then supplies the same complete original arguments.
        control.serializeEvent({ =>
            let meta = EventMeta(context.nextSequence(), control.traceId, context.runId,
                occurredAtMillis: agentUtcMillis(), turnId: control.currentTurnId(),
                requestId: match (control.currentRequestId()) { case "" => None; case value => Some(RequestId(value)) },
                toolBatchId: Some(batch), toolCallId: Some(ToolCallId(committed.block.callId)))
            let factory = CoreOwnedToolCallPayloadFactory(committed.block.name,
                ToolCallId(committed.block.callId), committed.canonicalItemId)
            let delivery = CoreOwnedCanonicalEventDelivery(read, guard, repository, sink, meta, factory)
            control.retainCanonicalDelivery(delivery)
            match (delivery.run()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => control.releaseCanonicalDelivery(delivery); Result.Ok(()) }
        })
    }

    private func emitExtension(
        context: ToolInvocationContext,
        control: CoreRunControl,
        kind: AgentEventKind,
        detail: AgentValue,
        sink: AgentEventSink,
        turnId!: ?TurnId = None,
        requestId!: ?RequestId = None,
        semanticRequestId!: ?SemanticModelRequestId = None,
        attemptId!: ?ModelAttemptId = None,
        toolBatchId!: ?ToolBatchId = None,
        toolCallId!: ?ToolCallId = None,
        operationId!: ?OperationId = None
    ): Result<Unit> {
        emitTyped(
            context,
            control,
            AgentEventPayload.Extension(kind, detail),
            sink,
            turnId: turnId,
            requestId: requestId,
            semanticRequestId: semanticRequestId,
            attemptId: attemptId,
            toolBatchId: toolBatchId,
            toolCallId: toolCallId,
            operationId: operationId
        )
    }

    private func emitTyped(
        context: ToolInvocationContext,
        control: CoreRunControl,
        payload: AgentEventPayload,
        sink: AgentEventSink,
        turnId!: ?TurnId = None,
        requestId!: ?RequestId = None,
        semanticRequestId!: ?SemanticModelRequestId = None,
        attemptId!: ?ModelAttemptId = None,
        toolBatchId!: ?ToolBatchId = None,
        toolCallId!: ?ToolCallId = None,
        operationId!: ?OperationId = None
    ): Result<Unit> {
        control.serializeEvent({ =>
            let event = AgentEvent(
                EventMeta(
                    context.nextSequence(),
                    control.traceId,
                    context.runId,
                    occurredAtMillis: agentUtcMillis(),
                    turnId: match (turnId) {
                        case Some(value) => Some(value)
                        case None => control.currentTurnId()
                    },
                    requestId: match (requestId) {
                        case Some(value) => Some(value)
                        case None => match (control.currentRequestId()) {
                            case "" => None
                            case value => Some(RequestId(value))
                        }
                    },
                    semanticRequestId: semanticRequestId,
                    attemptId: attemptId,
                    toolBatchId: match (toolBatchId) {
                        case Some(value) => Some(value)
                        case None => control.currentBatchId()
                    },
                    toolCallId: toolCallId,
                    operationId: operationId
                ),
                payload
            )
            match (runs.append(event)) {
                case Result.Ok(_) =>
                    sink(event)
                    Result.Ok(())
                case Result.Err(error) =>
                    if (isProvisionalStreamTelemetry(event)) {
                        sink(event)
                        Result.Ok(())
                    } else { Result.Err(error) }
            }
        })
    }

    private func emitAttemptLifecycle(
        context: ToolInvocationContext,
        control: CoreRunControl,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        code: String,
        sink: AgentEventSink,
        fields!: Array<ValueField> = []
    ): Result<Unit> {
        let values = ArrayList<ValueField>()
        values.add(ValueField("code", textValue(code)))
        values.add(ValueField("semantic_request_id", textValue(semanticRequestId.value)))
        values.add(ValueField("attempt_id", textValue(attemptId.value)))
        for (field in fields) { values.add(field) }
        emitExtension(
            context, control, AgentEventKind.Audit, objectValue(values.toArray()), sink,
            semanticRequestId: Some(semanticRequestId), attemptId: Some(attemptId)
        )
    }

    private func recordDurableDecisionLifecycle(
        result: Result<DurableModelResult>,
        context: ToolInvocationContext,
        control: CoreRunControl,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        sink: AgentEventSink
    ): Result<DurableModelResult> {
        match (result) {
            case Result.Ok(value) =>
                match (ensureModelAttemptBarrier(
                    attemptId, semanticRequestId,
                    ModelAttemptReplayBarrier.ProviderTerminal,
                    context, control, sink
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                let _ = emitAttemptLifecycle(
                    context, control, semanticRequestId, attemptId,
                    "model.decision_persisted", sink,
                    fields: [ValueField("decision_id", textValue(value.decision.id.value))]
                )
                Result.Ok(value)
            case Result.Err(error) =>
                if (error.kind == AgentErrorKind.Cancelled) {
                    match (ensureModelAttemptBarrier(
                        attemptId, semanticRequestId, ModelAttemptReplayBarrier.Cancelled,
                        context, control, sink
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(storeError) => return Result.Err(storeError)
                    }
                }
                let code = if (error.kind == AgentErrorKind.Cancelled) {
                    "model.attempt_cancelled"
                } else { "model.attempt_failed" }
                let _ = emitAttemptLifecycle(
                    context, control, semanticRequestId, attemptId, code, sink,
                    fields: [ValueField("error_code", textValue(error.code))]
                )
                Result.Err(error)
        }
    }

    private func ensureModelAttemptBarrier(
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        fallback: ModelAttemptReplayBarrier,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        let attempt = match (runs.modelAttempt(attemptId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
            return Result.Ok(())
        }
        markModelAttemptBarrier(
            attemptId, semanticRequestId, fallback, context, control, sink
        )
    }

    private func markModelAttemptBarrier(
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        barrier: ModelAttemptReplayBarrier,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        let event = AgentEvent(
            EventMeta(
                context.nextSequence(), control.traceId, context.runId,
                occurredAtMillis: agentUtcMillis(), turnId: control.currentTurnId(),
                semanticRequestId: Some(semanticRequestId), attemptId: Some(attemptId),
                toolBatchId: control.currentBatchId()
            ),
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                ValueField("code", textValue("model.attempt_replay_barrier")),
                ValueField("semantic_request_id", textValue(semanticRequestId.value)),
                ValueField("attempt_id", textValue(attemptId.value)),
                ValueField("barrier", textValue(modelAttemptReplayBarrierNameForCore(barrier)))
            ]))
        )
        match (runs.markModelAttemptReplayBarrier(attemptId, barrier, event)) {
            case Result.Ok(_) => sink(event); Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func emitTransition(
        context: ToolInvocationContext,
        control: CoreRunControl,
        transition: RunTransition,
        sink: AgentEventSink
    ): Result<Unit> {
        emitTyped(
            context,
            control,
            AgentEventPayload.RunStateChanged(
                transition.from,
                transition.to,
                transition.reason
            ),
            sink
        )
    }

    private func bindToolOutputSink(
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        outputSink: CoreToolOutputSink
    ): Unit {
        outputSink.bind({ chunk =>
            let callId = ToolCallId(chunk.callId)
            emitTyped(
                context,
                control,
                AgentEventPayload.ToolOutput(callId, chunk.channel, chunk.content),
                sink,
                toolCallId: Some(callId)
            )
        })
    }

    private func bindBudgetChargeHandler(
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Unit {
        context.setBudgetChargeHandler({ charge =>
            reserveBudget(control, context, charge, sink)
        })
        context.bindPaidExecutionFailureSink173(control)
        context.setOwnedTaskHandler({ name, task => control.runtime.ownTask(name, task,
            expectedRunId: Some(context.runId), expectedEpoch: Some(context.epoch)) })
        context.setDerivedToolFrameHandler({ parent, child, name, entering =>
            control.derivedToolFrame(parent, child, name, entering)
        })
        context.setNestedToolScheduler({ parentOperationId, action =>
            executeNestedToolSlot(
                control, context, parentOperationId, sink, action
            )
        })
    }

    // Preparation already charged the root ToolCall before waiting for User
    // approval. Resuming execution acquires only its live scheduler slot, so
    // nested work can yield that same slot without charging the root twice.
    private func withApprovalToolSlot(
        context: ToolInvocationContext,
        control: CoreRunControl,
        operationId: OperationId,
        toolName: String,
        sink: AgentEventSink,
        action: () -> Result<ToolInvocationResult>
    ): Result<ToolInvocationResult> {
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let usage = match (control.reserve(BudgetCharge(toolsStarted: 1))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        match (control.registerScheduledToolSlot(operationId, toolName)) {
            case Result.Err(error) =>
                match (control.ledger.releaseTools()) {
                    case Result.Err(releaseError) => return Result.Err(releaseError)
                    case Result.Ok(released) => match (emitTyped(
                        context, control, AgentEventPayload.BudgetUpdated(released), sink
                    )) {
                        case Result.Err(releaseError) => return Result.Err(releaseError)
                        case Result.Ok(_) => return Result.Err(error)
                    }
                }
            case Result.Ok(_) => ()
        }
        let outcome: Result<ToolInvocationResult> = try {
            match (emitTyped(context, control, AgentEventPayload.BudgetUpdated(usage), sink)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => match (context.cancellation.check()) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => action()
                }
            }
        } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.Internal, "tool.executor_panicked",
                "approved tool executor escaped its Result boundary",
                fields: [ErrorField("operation_id", operationId.value), ErrorField("tool", toolName)]))
        }
        var transferred = false
        try {
        // A failed nested admission can leave the parent yielded with no live
        // ledger slot. Follow the same ownership check as batch execution.
        if (control.unregisterScheduledToolSlot(operationId)) {
            match (control.ledger.releaseTools()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(released) => match (emitTyped(
                    context, control, AgentEventPayload.BudgetUpdated(released), sink
                )) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
            }
        }
        transferred = true
        outcome
        } finally { if (!transferred) { releaseToolInvocationPayload(outcome) } }
    }

    private func executeNestedToolSlot(
        control: CoreRunControl,
        context: ToolInvocationContext,
        parentOperationId: OperationId,
        sink: AgentEventSink,
        action: () -> Result<Unit>
    ): Result<Unit> {
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (control.beginNestedToolSlot(parentOperationId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let parentUsage = match (control.ledger.releaseTools()) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = control.restoreYieldedToolSlot(parentOperationId)
                return Result.Err(error)
        }
        match (emitTyped(
            context,
            control,
            AgentEventPayload.BudgetUpdated(parentUsage),
            sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                match (resumeYieldedToolSlot(
                    control, context, parentOperationId, sink
                )) {
                    case Result.Ok(_) => return Result.Err(error)
                    case Result.Err(resumeError) => return Result.Err(resumeError)
                }
        }
        match (context.cancellation.check()) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                match (resumeYieldedToolSlot(
                    control, context, parentOperationId, sink
                )) {
                    case Result.Ok(_) => return Result.Err(error)
                    case Result.Err(resumeError) => return Result.Err(resumeError)
                }
        }
        let childUsage = match (control.reserve(BudgetCharge(
            toolCalls: 1,
            toolsStarted: 1
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                match (resumeYieldedToolSlot(
                    control, context, parentOperationId, sink
                )) {
                    case Result.Ok(_) => return Result.Err(error)
                    case Result.Err(resumeError) => return Result.Err(resumeError)
                }
        }
        match (control.activateNestedToolSlot(parentOperationId)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = control.restoreYieldedToolSlot(parentOperationId)
                return Result.Err(error)
        }
        match (emitTyped(
            context,
            control,
            AgentEventPayload.BudgetUpdated(childUsage),
            sink
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = control.returnNestedToolSlot(parentOperationId)
                return Result.Err(error)
        }
        match (context.cancellation.check()) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                match (control.returnNestedToolSlot(parentOperationId)) {
                    case Result.Ok(_) => return Result.Err(error)
                    case Result.Err(slotError) => return Result.Err(slotError)
                }
        }
        let childResult: Result<Unit> = try {
            action()
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "tool.scheduler_child_panicked",
                "nested tool execution escaped its Result boundary",
                fields: [ErrorField("parent_operation_id", parentOperationId.value)]
            ))
        }
        match (control.returnNestedToolSlot(parentOperationId)) {
            case Result.Ok(_) => childResult
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func resumeYieldedToolSlot(
        control: CoreRunControl,
        context: ToolInvocationContext,
        parentOperationId: OperationId,
        sink: AgentEventSink
    ): Result<Unit> {
        let usage = match (control.reserve(BudgetCharge(toolsStarted: 1))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (control.restoreYieldedToolSlot(parentOperationId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        emitTyped(
            context,
            control,
            AgentEventPayload.BudgetUpdated(usage),
            sink
        )
    }

    private func reserveContextBoundaryTurn(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: BudgetCounter, state: CoreToolLoopState, sink: AgentEventSink): Result<TurnId> {
        let boundary = match (runs.contextBoundary(request.runId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (boundary.isNone()) {
            match (reserveBudget(control, context, BudgetCharge(turns: 1), sink)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return Result.Ok(control.nextTurnId()) }
        control.requireContextBoundaryPrepare()
        if (counter.turns == Int64.Max || contextBoundaryText(boundary.getOrThrow().data(), "point") != "after_safe_cut") {
            return Result.Err(coreContextBoundaryError("another turn already owns this boundary")) }
        let reservation = CoreBoundaryTurnReservation()
        let outcome = control.serializeEvent({ =>
            let usage = match (control.reserve(BudgetCharge(turns: 1))) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let turn = control.nextTurnId()
            let event = AgentEvent(EventMeta(context.nextSequence(), control.traceId, context.runId,
                occurredAtMillis: agentUtcMillis(), turnId: Some(turn)), AgentEventPayload.BudgetUpdated(usage))
            let replacement = coreContextBoundaryReservedData(boundary.getOrThrow().data(), counter, control, usage)
            match (runs.reserveContextBoundaryTurn(boundary.getOrThrow(), event, replacement)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => reservation.turn = Some(turn); sink(event); Result.Ok(()) }
        })
        match (outcome) { case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(reservation.turn.getOrThrow()) }
    }

    private func reserveBudget(
        control: CoreRunControl,
        context: ToolInvocationContext,
        charge: BudgetCharge,
        sink: AgentEventSink,
        turnId!: ?TurnId = None,
        requestId!: ?RequestId = None,
        toolBatchId!: ?ToolBatchId = None,
        toolCallId!: ?ToolCallId = None,
        observedUsage!: ?ModelUsage = None
    ): Result<ExecutionUsage> {
        match (control.reserve(charge)) {
            case Result.Ok(usage) =>
                match (emitTyped(
                    context,
                    control,
                    AgentEventPayload.BudgetUpdated(usage),
                    sink,
                    turnId: turnId,
                    requestId: requestId,
                    toolBatchId: toolBatchId,
                    toolCallId: toolCallId
                )) {
                    case Result.Ok(_) => Result.Ok(usage)
                    case Result.Err(error) => Result.Err(error)
                }
            case Result.Err(error) =>
                match (observedUsage) {
                    case Some(value) => let _ = control.ledger.recordObservedUsage(value)
                    case None => ()
                }
                Result.Err(error)
        }
    }

    func executeCanonicalInternal(request: ModelRequest, options: InternalModelCallOptions,
        events: ModelEventSink): Result<ModelReply> {
        if (options.parent.isNone() || options.purpose.isNone() || !request.tools.isEmpty() || request.parallelToolCalls ||
            match (request.toolChoice) { case ModelToolChoice.NoTools => false; case _ => true }) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "model.internal_input_invalid",
                "internal model calls require a typed purpose, real parent and no tools"))
        }
        match (checkInternalCallCancellation(options)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let parent = options.parent.getOrThrow()
        let purpose = options.purpose.getOrThrow()
        let maintenance = purpose == InternalModelPurpose.ContextCompaction
        let control: CoreRunControl
        if (maintenance) {
            let runtime = match (threadRuntimes.acquire(ThreadId(parent.sessionId.value), coreWorkspaceId(parent))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            control = CoreRunControl(parent.runId, parent.budget, runtime, callerCancellation180: parent.callerCancellation180,
                recoveryPolicy180: modelAttemptRecoveryForSettings180(parent.toolContext.executionSettings180, modelAttemptRecovery))
            match (controls.add(control)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            control.bindCancellation(model, tools)
            let admission = runtime.startInternalModelTurn(SemanticTurnId("turn-" + parent.runId.value), parent.runId,
                ItemId("maintenance-" + parent.runId.value), coreInternalMaintenanceLane(parent), parent.contextSnapshot,
                agentUtcMillis(), parent.budget.deadlineMillis, coreBudgetSnapshot(parent.budget), executionLaneId: parent.executionLaneId, parentCancellation: options.cancellation)
            match (admission) {
                case Result.Err(error) => finishControl(parent.runId); return Result.Err(error)
                case Result.Ok(value) =>
                    match (control.bindRuntimeCancellation(value.epoch)) {
                        case Result.Err(error) =>
                            let _ = control.finish(RunState.RecoveryRequired, reason: "run.cancellation_link_failed")
                            finishControl(parent.runId); return Result.Err(error)
                        case Result.Ok(_) => ()
                    }
            }
            match (runs.save(RunSnapshot(parent.runId, parent.sessionId, RunState.Running,
                summary: "internal model maintenance", kind: RunKind.Compaction))) {
                case Result.Err(error) => let _ = control.finish(RunState.Failed); finishControl(parent.runId); return Result.Err(error)
                case Result.Ok(_) => ()
            }
        } else {
            control = match (internalModelControl(parent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        }
        let canonical = CoreInternalAttemptPort(model, runs, modelDecisionRuntime, control, parent, purpose, catalog)
        // Register against the durable owner before the bounded loop. An
        // already-cancelled token invokes this callback immediately, closing
        // the old set-active / model-registration race without a second loop.
        let cancellation: ?InternalCallCancellationRegistration = match (options.cancellation) {
            case Some(token) => Some(token.onCancel({ _ => let _ = canonical.cancel(request.requestId) }))
            case None => None }
        var outcome: Result<ModelReply> = Result.Err(AgentError(AgentErrorKind.Internal,
            "model.internal_unsettled", "internal model call did not return"))
        try {
            match (model.registerInternalCancellation(request.requestId, { => canonical.cancel(request.requestId) })) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let bounded = ControlledModelPort(canonical, runs: Some(runs))
            bounded.bindBudgetController(AgentCoreInternalModelBudgetController(this))
            outcome = try { bounded.executeInternalLoop(request, InternalModelCallOptions(parent: Some(parent),
                timeoutMillis: options.timeoutMillis, maxAttempts: options.maxAttempts, cancellation: options.cancellation), events) }
                finally { model.releaseInternalCancellation(request.requestId) }
        } catch (_: Exception) {
            outcome = Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.internal_boundary_failed",
                "internal model boundary ended without a reliable settlement"))
        } finally {
            match (cancellation) { case Some(registration) => registration.dispose(); case None => () }
            if (maintenance) {
                let wasCancelled = match (outcome) { case Result.Err(error) => error.kind == AgentErrorKind.Cancelled
                    case Result.Ok(_) => false }
                let settled: Result<Unit> = if (isTerminalRunState(control.state())) { Result.Ok(()) }
                else if (wasCancelled) {
                    match (control.settleCancellation(CancellationReason(CancellationReasonKind.User,
                        "model.internal_cancelled", "internal model maintenance was cancelled", cancelledAtMillis: agentUtcMillis()))) {
                        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(()) }
                } else {
                    match (control.finish(if (outcome.isOk()) { RunState.Completed } else { RunState.Failed },
                        reason: "internal model maintenance settled")) {
                        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(()) }
                }
                // The Runtime's actual join report remains terminal authority.
                match (settled) { case Result.Err(error) => outcome = Result.Err(error); case Result.Ok(_) => () }
                if (control.state() == RunState.RecoveryRequired) {
                    outcome = Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "model.internal_resources_unsettled", "maintenance resources have not acknowledged cleanup")) }
                match (runs.find(parent.runId)) {
                    case Result.Ok(value) =>
                        match (runs.save(copyInternalSnapshot(value, status: Some(control.state())))) {
                            case Result.Err(error) => outcome = Result.Err(error); case Result.Ok(_) => () }
                    case Result.Err(error) => outcome = Result.Err(error)
                }
                finishControl(parent.runId)
            }
        }
        outcome
    }

    func reserveInternalModelRequest(parent: AgentRunRequest): Result<Unit> {
        let control = match (internalModelControl(parent)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (control.reserve(BudgetCharge(modelRequests: 1))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    func accountInternalModelUsage(
        parent: AgentRunRequest,
        usage: ModelUsage
    ): Result<Unit> {
        let control = match (internalModelControl(parent)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let cost = match (usage.costMicros) {
            case Some(value) => value
            case None => 0
        }
        match (control.reserve(BudgetCharge(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            costMicros: cost
        ))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                let _ = control.ledger.recordObservedUsage(usage)
                Result.Err(error)
        }
    }

    private func internalModelControl(
        parent: AgentRunRequest
    ): Result<CoreRunControl> {
        match (controls.find(parent.runId)) {
            case Some(control) => Result.Ok(control)
            case None =>
                let snapshot = match (runs.find(parent.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (snapshot.status != RunState.WaitingApproval) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "model.internal_run_control_missing",
                        "internal model call has no active approval Run control"
                    ))
                }
                controlForResume(parent, snapshot, internalNoToolsRecovery: true)
        }
    }

    private func controlForResume(
        request: AgentRunRequest,
        snapshot: RunSnapshot,
        modelRecovery!: Bool = false,
        internalNoToolsRecovery!: Bool = false,
        initialUsage!: ?ExecutionUsage = None
    ): Result<CoreRunControl> {
        match (controls.find(request.runId)) {
            case Some(value) => Result.Ok(value)
            case None =>
                let runtime = match (threadRuntimes.recover(
                    ThreadId(request.sessionId.value),
                    coreWorkspaceId(request)
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let restoredOwner = runtime.activeRun()
                match (restoredOwner) {
                    case Some(active) =>
                        if (active.runId.value != request.runId.value ||
                            (!modelRecovery && active.state != RunState.WaitingApproval) ||
                            (modelRecovery && active.state != RunState.Running &&
                                active.state != RunState.RecoveryRequired)) {
                            return Result.Err(AgentError(
                                AgentErrorKind.RecoveryRequired,
                                "run.resume_owner_mismatch",
                                "canonical Thread owner does not match the durable continuation"
                            ))
                        }
                        match (validateCoreModelLane159(active.lane, ThreadId(request.sessionId.value))) {
                            case Result.Ok(_) => ()
                            case Result.Err(error) => return Result.Err(error)
                        }
                    case None =>
                        if (!internalNoToolsRecovery) {
                            return Result.Err(AgentError(
                                AgentErrorKind.RecoveryRequired,
                                "run.model_lane_snapshot_missing",
                                "canonical Thread has no active Run snapshot to restore"
                            ))
                        }
                }
                let restoredModelRequests = match (initialUsage) {
                    case Some(value) => value.modelRequests + value.drainModelRequests
                    case None => snapshot.modelRequests
                }
                let control = CoreRunControl(
                    request.runId,
                    request.budget,
                    runtime,
                    initial: if (modelRecovery) { RunState.Running } else { RunState.WaitingApproval },
                    turns: snapshot.turns,
                    modelRequests: restoredModelRequests, callerCancellation180: request.callerCancellation180,
                    recoveryPolicy180: modelAttemptRecoveryForSettings180(request.toolContext.executionSettings180, modelAttemptRecovery)
                )
                // Budget continuity across crash/resume: prefer the exact
                // durable checkpoint usage over the coarser Run snapshot so a
                // resumed run can never re-enter the loop with fresh budget.
                let restoredUsage = match (initialUsage) {
                    case Some(value) => value
                    case None => ExecutionUsage(
                        turns: snapshot.turns,
                        modelRequests: snapshot.modelRequests,
                        toolCalls: snapshot.toolCalls,
                        inputTokens: snapshot.inputTokens,
                        outputTokens: snapshot.outputTokens,
                        costMicros: match (snapshot.costMicros) {
                            case Some(value) => value
                            case None => 0
                        }
                    )
                }
                control.ledger.restore(restoredUsage)
                // Legacy internal budget accounting may restore counters
                // without a semantic Run. It has no Runtime cancellation owner
                // to bind. The None branch above remains exclusive to that
                // no-tools accounting path; real resume/Attempt owners still
                // require the exact admitted Run and epoch below.
                match (restoredOwner) {
                    case Some(owner) =>
                        match (control.bindRuntimeCancellation(owner.epoch)) {
                            case Result.Err(error) => control.close(); return Result.Err(error)
                            case Result.Ok(_) => ()
                        }
                    case None => ()
                }
                match (controls.add(control)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => control.close(); return Result.Err(error)
                }
                control.bindCancellation(model, tools)
                Result.Ok(control)
        }
    }

    private func finishControl(runId: RunId): Unit {
        match (controls.remove(runId)) {
            case Some(value) => value.close()
            case None => ()
        }
    }

    private func emitToolOutcome(
        context: ToolInvocationContext,
        toolName: String,
        outcome: ToolInvocationResult,
        arguments: AgentValue,
        sink: AgentEventSink,
        toolBatchId!: ?ToolBatchId = None,
        toolCallId!: ?ToolCallId = None
    ): Result<Unit> {
        match (outcome) {
            case ToolInvocationResult.Completed(result) =>
                match (emitExtension(
                    context,
                    match (controls.find(context.runId)) {
                        case Some(value) => value
                        case None => return Result.Err(AgentError(
                            AgentErrorKind.Internal,
                            "run.control_missing",
                            "active run control is missing"
                        ))
                    },
                    AgentEventKind.Tool,
                    objectValue(
                        [
                            ValueField(
                                "code",
                                textValue("tool.execution_completed")
                            ),
                            ValueField("name", textValue(toolName)),
                            ValueField(
                                "call_id",
                                textValue(result.callId)
                            ),
                            ValueField("output", result.output),
                            ValueField(
                                "is_error",
                                boolValue(result.isError)
                            ),
                            ValueField(
                                "receipt_id",
                                textValue(result.receiptId)
                            )
                        ]
                    ),
                    sink,
                    toolBatchId: toolBatchId,
                    toolCallId: toolCallId
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                Result.Ok(())
            case ToolInvocationResult.Denied(denial) => emitExtension(
                context,
                match (controls.find(context.runId)) {
                    case Some(value) => value
                    case None => return Result.Err(AgentError(
                        AgentErrorKind.Internal,
                        "run.control_missing",
                        "active run control is missing"
                    ))
                },
                AgentEventKind.Tool,
                objectValue(
                    [
                        ValueField(
                            "code",
                            textValue("tool.execution_completed")
                        ),
                        ValueField("name", textValue(toolName)),
                        ValueField(
                            "call_id",
                            textValue(denial.callId)
                        ),
                        ValueField(
                            "output",
                            objectValue(
                                [
                                    ValueField(
                                        "error",
                                        textValue(denial.reason.code)
                                    )
                                ]
                            )
                        ),
                        ValueField("is_error", boolValue(true)),
                        ValueField("receipt_id", textValue(""))
                    ]
                ),
                sink,
                toolBatchId: toolBatchId,
                toolCallId: toolCallId
            )
            case ToolInvocationResult.NeedsApproval(_) => Result.Ok(())
        }
    }

    private func forwardModelEvent(
        context: ToolInvocationContext,
        control: CoreRunControl,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        event: ModelEvent,
        sink: AgentEventSink
    ): Result<Unit> {
        let payload = match (event) {
            case ModelEvent.TextDelta(value) => AgentEventPayload.TextDelta(value)
            case ModelEvent.ReasoningDelta(value) => AgentEventPayload.ReasoningDelta(value)
            case ModelEvent.UsageUpdated(input, output) => AgentEventPayload.ModelUsageUpdated(
                ModelUsage(inputTokens: input, outputTokens: output)
            )
            case _ => AgentEventPayload.Extension(
                AgentEventKind.Model,
                modelEventValue(event)
            )
        }
        control.serializeEvent({ =>
            let durableEvent = AgentEvent(
                EventMeta(
                    context.nextSequence(), control.traceId, context.runId,
                    occurredAtMillis: agentUtcMillis(),
                    turnId: control.currentTurnId(),
                    requestId: match (control.currentRequestId()) {
                        case "" => None
                        case value => Some(RequestId(value))
                    },
                    semanticRequestId: Some(semanticRequestId),
                    attemptId: Some(attemptId),
                    toolBatchId: control.currentBatchId()
                ),
                payload
            )
            match (runs.append(durableEvent)) {
                case Result.Ok(_) =>
                    sink(durableEvent)
                    Result.Ok(())
                case Result.Err(_) =>
                    let dropped = AgentEvent(
                        durableEvent.meta,
                        AgentEventPayload.Extension(AgentEventKind.Diagnostic, objectValue([
                            ValueField("code", textValue("model.stream_telemetry_dropped"))
                        ]))
                    )
                    match (runs.append(dropped)) {
                        case Result.Ok(_) =>
                            sink(dropped)
                            Result.Ok(())
                        case Result.Err(error) => Result.Err(error)
                    }
            }
        })
    }

    private func persistFirstModelAttemptBarrier(
        activity: AttemptDeadlineContext,
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        barrier: ModelAttemptReplayBarrier,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        activity.persistFirstReplayBarrier(barrier, { =>
            markModelAttemptBarrier(
                attemptId, semanticRequestId, barrier, context, control, sink
            )
        })
    }
    private func persistDeferredModelAttemptBarrier(
        execution: ModelAttemptExecution,
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        if (execution.replayBarrier != ModelAttemptReplayBarrier.ProviderTerminal) {
            return Result.Ok(())
        }
        ensureModelAttemptBarrier(
            attemptId, semanticRequestId, ModelAttemptReplayBarrier.ProviderTerminal,
            context, control, sink
        )
    }

    // Explicit typed caller wrappers use this same AgentCore and its actual
    // canonical start/approval/recovery methods. No second scheduler or Source.
    public func startOwnedOuterError333(request:AgentRunRequest,sink:AgentEventSink):OwnedAgentRunResult333{
        ownedOuterErrorResult333(request.runId,start(request,sink))
    }
    public func resumeOwnedOuterError333(request:AgentRunRequest,sink:AgentEventSink):OwnedAgentRunResult333{
        ownedOuterErrorResult333(request.runId,resume(request,sink))
    }
    public func decideOwnedOuterError333(request:AgentRunRequest,approval:ApprovalRequest,
        decision:ApprovalDecision,sink:AgentEventSink):OwnedAgentRunResult333{
        ownedOuterErrorResult333(request.runId,decide(request,approval,decision,sink))
    }
    private func ownedOuterErrorResult333(run:RunId,original:Result<AgentRunOutcome>):OwnedAgentRunResult333{
        match(controls.find(run)){case Some(control)=>
            if(!control.isOuterPublicationBlocked333()){
                match(control.outerFailureData333()){case Some(value)=>
                    return match(value.retainCallerAlias333()){
                        case Result.Ok(_)=>OwnedAgentRunResult333.Failed(value)
                        case Result.Err(_)=>OwnedAgentRunResult333.Held}
                    case None=>()}}
            match(control.outerErrorData333()){case Some(value)=>
                return try{OwnedAgentRunResult333.Pending(OwnedOuterErrorPending333(value))}
                    catch(_:Exception){OwnedAgentRunResult333.Held}
                case None=>()}
            case None=>()}
        OwnedAgentRunResult333.Existing(original)
    }
    private func retainOuterPublicationFailure333(control:CoreRunControl,value:OwnedOuterErrorFailure333,
        error:AgentError):Unit{
        // A failed invoice is explicit pending publication, never permission
        // to merge/copy an unpaid full secondary error into another carrier.
        match(value.retainSupplement(error)){case Result.Err(_)=>control.blockOuterPublication333();case Result.Ok(_)=>()}
    }
    private func failOwnedOuterError333(request:AgentRunRequest,context:ToolInvocationContext,
        control:CoreRunControl,source:PluginLivePolicyPaidOuterErrorSource333,sink:AgentEventSink,
        counter:?BudgetCounter):Result<AgentRunOutcome>{
        if(control.outerFailureData333().isSome() || control.isOuterPublicationBlocked333()){
            return Result.Err(coreOwnedOuterErrorPending333())}
        // Only the new exact returned-frame path can close original physical
        // debt. Copied data stays in this same Core control even after ACK.
        let physical=source.withPaidError333({_,fund=>control.closeOuterPhysicalDebt334(fund)})
        match(physical){case Result.Err(error)=>let _=control.retainOuterSupplement333(error);case Result.Ok(_)=>()}
        // The original canonical Run and its original resource debt remain
        // authoritative. In particular 326 may deny this transition while
        // its actual SQLite debt is open. Do not invent a terminal snapshot.
        let transition=source.withPaidError333({error,fund=>
            match(fund(ownedOuterErrorAdd333(32768,ownedOuterErrorMultiply333(error.code.size,32)))){
                case Result.Err(value)=>return Result.Err(value);case Result.Ok(_)=>()}
            if(isTerminalRunState(control.state())){return Result.Ok(())}
            match(control.finish(RunState.RecoveryRequired,reason:error.code)){
                case Result.Err(value)=>Result.Err(value)
                case Result.Ok(value)=>emitTransition(context,control,value,sink)}})
        match(transition){case Result.Err(value)=>let _=control.retainOuterSupplement333(value);case Result.Ok(_)=>()}
        if(control.state()!=RunState.RecoveryRequired || control.isOuterPublicationBlocked333()){
            return Result.Err(coreOwnedOuterErrorPending333())}
        // Sequence allocation and the complete Diagnostic append/delivery
        // use the existing ordered event lock, just as ordinary emitTyped.
        let _=control.serializeEvent({=>
            let value:OwnedOuterErrorFailure333=try{
                let budget=match(counter){case Some(actual)=>actual;case None=>BudgetCounter()}
                let metadata=RunSnapshot(request.runId,request.sessionId,control.state(),
                    sequence:context.currentSequence(),modelRequests:budget.modelRequests,usage:budget.usage(),
                    lastInputTokens:budget.lastInputTokens,lastOutputTokens:budget.lastOutputTokens,
                    lastRequestDurationMillis:budget.lastRequestDurationMillis,toolCalls:budget.toolCalls,turns:budget.turns)
                let event=EventMeta(context.nextSequence(),control.traceId,request.runId,
                    occurredAtMillis:agentUtcMillis(),turnId:control.currentTurnId(),
                    requestId:match(control.currentRequestId()){case ""=>None;case id=>Some(RequestId(id))},
                    toolBatchId:control.currentBatchId())
                OwnedOuterErrorFailure333(source,metadata,event)
            }catch(_:Exception){control.blockOuterPublication333();return Result<Unit>.Err(coreOwnedOuterErrorPending333())}
            match(control.publishOuterFailure333(value)){
                case Result.Err(_)=>control.blockOuterPublication333();return Result<Unit>.Err(coreOwnedOuterErrorPending333())
                case Result.Ok(_)=>()}
            match(runs as OwnedOuterErrorRunRepository333){case Some(repository)=>
                match(repository.saveOwnedOuterError333(value)){
                    case Result.Err(error)=>retainOuterPublicationFailure333(control,value,error)
                    case Result.Ok(_)=>()}
                match(repository.appendOwnedOuterError333(value)){
                    case Result.Err(error)=>retainOuterPublicationFailure333(control,value,error)
                    case Result.Ok(_)=>match(request.ownedEvents){case Some(actual)=>
                        match(actual as OwnedOuterErrorEventSink333){
                            case Some(target)=>match(target.emitOwnedOuterError333(value)){
                                case Result.Err(error)=>retainOuterPublicationFailure333(control,value,error);case Result.Ok(_)=>()}
                            case None=>retainOuterPublicationFailure333(control,value,AgentError(AgentErrorKind.RecoveryRequired,
                                "run.owned_outer_error_sink_required","Diagnostic awaits a funded typed observer"))}
                        case None=>retainOuterPublicationFailure333(control,value,AgentError(AgentErrorKind.RecoveryRequired,
                            "run.owned_outer_error_sink_required","Diagnostic awaits a funded typed observer"))}}
                case None=>retainOuterPublicationFailure333(control,value,AgentError(AgentErrorKind.RecoveryRequired,
                    "run.owned_outer_error_repository_required","full snapshot and Diagnostic await a funded typed repository"))}
            Result<Unit>.Ok(())})
        finishControl(request.runId)
        Result.Err(coreOwnedOuterErrorPending333())
    }

    private func afterCoreResultPersistedOwned113(context: ToolInvocationContext,
        control: CoreRunControl, toolName: String, outcome: ToolInvocationResult,
        originalPlan: ?NormalizedOperationPlan, primary!: Bool = true): Result<Unit> {
        match (tools.afterResultPersistedWithPlanOwned113(context, toolName, outcome, originalPlan)) {
            case OwnedPostCanonicalObserverDispatch113.Existing(value) => value
            case OwnedPostCanonicalObserverDispatch113.Owned(OwnedFailureDataOutcome113.Value(_)) => Result<Unit>.Ok(())
            case OwnedPostCanonicalObserverDispatch113.Owned(OwnedFailureDataOutcome113.Failure(consumer)) =>
                // The real callback transferred its already-paid DATA share.
                // No naked dynamic AgentError is returned through the old API.
                let marker = control.captureCheckpointFailure113(consumer, primary: primary)
                Result.Err(marker)
        }
    }

    public func startOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        let result = start(request, sink)
        let _ = flushOwnedCheckpointFailures113(request.runId, events: request.ownedEvents)
        ownedCheckpointFailureResult113(request.runId, result)
    }
    public func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        let result = resumeContextBoundary(request, sink)
        let _ = flushOwnedCheckpointFailures113(request.runId, events: request.ownedEvents)
        ownedCheckpointFailureResult113(request.runId, result)
    }
    public func resumeOwnedCheckpointFailure113(request: AgentRunRequest,
        sink: AgentEventSink): OwnedAgentRunResult113 {
        let result = resume(request, sink)
        let _ = flushOwnedCheckpointFailures113(request.runId, events: request.ownedEvents)
        ownedCheckpointFailureResult113(request.runId, result)
    }
    public func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest,
        decision: ApprovalDecision, sink: AgentEventSink): OwnedAgentRunResult113 {
        let result = decide(request, approval, decision, sink)
        let _ = flushOwnedCheckpointFailures113(request.runId, events: request.ownedEvents)
        ownedCheckpointFailureResult113(request.runId, result)
    }
    // Explicit polling transfers another actual error from a committed wave;
    // it does not re-execute a tool, repeat an observer or allocate a sequence.
    // Finish each already-prepared original publication's one-off producer
    // calls even when an earlier Event still waits for actual asynchronous
    // ACK. This neither retries failed save/append nor allocates a sequence.
    public func prepareOwnedCheckpointWave113(run: RunId,
        events!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>): (Bool, Int64, Int64) {
        let control = match (controls.find(run)) { case Some(value) => value; case None => return (false, 0, 0) }
        if (control.hasCheckpointConsumerFrame113()) { return (false, 0, 0) }
        let prepared = control.serializeEvent({ =>
            var selected = control.checkpointFailureHead113()
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (!entry.beginWork()) { return Result<Unit>.Err(coreOwnedCheckpointFailurePending113()) }
                try {
                    if (entry.publication.isSome()) { let _ = deliverCheckpointPublication113(entry, control, events) }
                } finally { entry.endWork() }
                selected = entry.next
            }
            Result<Unit>.Ok(())
        })
        match (prepared) { case Result.Err(_) => return (false, 0, 0); case Result.Ok(_) => () }
        control.checkpointWaveCounts113()
    }

    public func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool {
        match (controls.find(run)) { case Some(value) => value.checkpointEventExpectation113(sequence); case None => None<Bool> }
    }

    public func retireOwnedCheckpointProducerWitness113(run: RunId): Unit {
        match (controls.find(run)) { case Some(value) => value.retireCheckpointReturnWitness113(); case None => () }
    }

    public func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 {
        let _ = flushOwnedCheckpointFailures113(run)
        ownedCheckpointFailureResult113(run, Result<AgentRunOutcome>.Err(coreOwnedCheckpointFailurePending113()))
    }
    private func ownedCheckpointFailureResult113(run: RunId,
        original: Result<AgentRunOutcome>): OwnedAgentRunResult113 {
        let control = match (controls.find(run)) {
            case None => return OwnedAgentRunResult113.Existing(original)
            case Some(value) => value }
        if (!control.hasCheckpointFailure113()) { return OwnedAgentRunResult113.Existing(original) }
        var selected = control.checkpointFailureHead113()
        while (selected.isSome()) {
            let entry = selected.getOrThrow()
            if (!entry.beginWork()) { return OwnedAgentRunResult113.Held }
            var answer: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
            var pending: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
            try {
                if (!entry.callerTransferred) {
                    match (entry.publication) {
                        case Some(publication) => match (publication.retainConsumer()) {
                            case Result.Err(_) => return OwnedAgentRunResult113.Held
                            case Result.Ok(value) => answer = Some(value); entry.callerTransferred = true }
                        case None => match (entry.consumer) {
                            case None => return OwnedAgentRunResult113.Held
                            case Some(consumer) => match (consumer.retainConsumer()) {
                                case Result.Err(_) => return OwnedAgentRunResult113.Held
                                case Result.Ok(value) => pending = Some(value); entry.callerTransferred = true } } }
                }
            } finally { entry.endWork() }
            match (answer) {
                case Some(value) =>
                    // The returned caller owns its distinct share. Retirement
                    // of Core's share cannot refund that actual caller alias.
                    let _ = control.retireCheckpointFailures113()
                    finishControl(run)
                    return OwnedAgentRunResult113.Failed(value)
                case None => () }
            match (pending) { case Some(value) => return OwnedAgentRunResult113.Pending(value); case None => () }
            selected = entry.next
        }
        let _ = control.retireCheckpointFailures113()
        if (control.hasCheckpointFailure113()) { return OwnedAgentRunResult113.Held }
        finishControl(run)
        OwnedAgentRunResult113.Existing(original)
    }

    private func failOwnedCheckpointFailure113(request: AgentRunRequest,
        context: ToolInvocationContext, control: CoreRunControl, sink: AgentEventSink,
        counter: ?BudgetCounter): Result<AgentRunOutcome> {
        let entry = match (control.checkpointFailureHead113()) {
            case None => return Result.Err(coreOwnedCheckpointFailurePending113())
            case Some(value) => value }
        // Borrow only a scalar classification. Dynamic code/message/fields
        // and all eight-field error data remain in the owned DATA holder.
        if (!entry.beginWork()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        let kind = try {
            if (entry.publication.isSome()) {
                let value = entry.publication.getOrThrow()
                match (value.withError({ _, fund => fund(4096) })) {
                    case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
                let actual = CoreCheckpointFailureKind143()
                match (value.withError({ error, _ => actual.value = error.kind; Result<Unit>.Ok(()) })) {
                    case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
                actual
            } else {
                let consumer = match (entry.consumer) { case Some(value) => value
                    case None => return Result.Err(coreOwnedCheckpointFailurePending113()) }
                match (coreCheckpointMetadataCellPayment143(consumer)) {
                    case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
                let actual = CoreCheckpointFailureKind143()
                match (consumer.withError({ error, _ => actual.value = error.kind })) {
                    case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
                actual
            }
        } finally { entry.endWork() }
        if (!isTerminalRunState(control.state())) {
            if (kind.value == AgentErrorKind.Cancelled) {
                let reason = CancellationReason(CancellationReasonKind.User,
                    "run.owned_checkpoint_failure", "actual post-canonical observer cancelled",
                    cancelledAtMillis: agentUtcMillis())
                let _ = control.requestCancel(CancellationReasonKind.User, reason.code, reason.message)
                match (control.settleCancellation(reason)) {
                    case Result.Err(_) => ()
                    case Result.Ok(values) => for (value in values) { let _ = emitTransition(context, control, value, sink) } }
            } else {
                let terminal = if (kind.value == AgentErrorKind.RecoveryRequired) { RunState.RecoveryRequired } else { RunState.Failed }
                match (control.finish(terminal, reason: "run.owned_checkpoint_failure")) {
                    case Result.Err(_) => ()
                    case Result.Ok(value) => let _ = emitTransition(context, control, value, sink) }
            }
        }
        // Actual Run authority may reject the transition while physical debt
        // remains. Never fabricate a terminal RunSnapshot in that case.
        let _ = publishCheckpointFailures113(request, context, control, counter, true)
        finishControl(request.runId)
        Result.Err(entry.marker)
    }

    private func prepareCheckpointPublication113(entry: CoreCheckpointFailureEntry113,
        request: AgentRunRequest, context: ToolInvocationContext, control: CoreRunControl,
        counter: ?BudgetCounter, status: RunState, ownsRunFailure: Bool): Result<Unit> {
        if (entry.publication.isNone()) {
            let consumer = entry.consumer.getOrThrow()
            // Pay before constructing the escaping metadata DTOs.
            match (coreCheckpointMetadataCellPayment143(consumer)) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
            let paid = CoreCheckpointMetadataResult143()
            match (consumer.withError({ _, fund => paid.value = fund(coreOwnedCheckpointMetadataPeak113(request, context, control)) })) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
            match (paid.value) { case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(_) => () }
            let budget = match (counter) { case Some(value) => value; case None => BudgetCounter() }
            let snapshot = RunSnapshot(request.runId, request.sessionId, status,
                sequence: context.currentSequence(), modelRequests: budget.modelRequests, usage: Some(budget.usage()),
                lastInputTokens: budget.lastInputTokens, lastOutputTokens: budget.lastOutputTokens,
                lastRequestDurationMillis: budget.lastRequestDurationMillis, toolCalls: budget.toolCalls, turns: budget.turns)
            let event = EventMeta(context.nextSequence(), control.traceId, request.runId,
                occurredAtMillis: agentUtcMillis(), turnId: control.currentTurnId(),
                requestId: match (control.currentRequestId()) { case "" => None<RequestId>; case id => Some(RequestId(id)) },
                toolBatchId: control.currentBatchId())
            // Constructor derives its OWN share. The original
            // callback consumer retires only after that succeeds.
            entry.publication = Some(OwnedFailureRunPublication113(consumer, snapshot, event))
        }
        match (entry.consumer) {
            case Some(value) => match (value.acknowledgeAfterConsumption()) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113())
                case Result.Ok(_) => entry.consumer = None<OwnedFailureDataConsumer113> }
            case None => () }
        // Preserve the first original fatal Run; every secondary still has
        // its own full Diagnostic/caller publication, not a naked Err alias.
        if (!ownsRunFailure || !entry.primary) { entry.saved = true }
        Result<Unit>.Ok(())
    }
    private func deliverCheckpointPublication113(entry: CoreCheckpointFailureEntry113,
        control: CoreRunControl, events: ?OwnedAgentEventSink): Result<Unit> {
        let publication = entry.publication.getOrThrow()
        let repository = match (runs as OwnedFailureRunRepository113) {
            case None => return Result.Err(coreOwnedCheckpointFailurePending113()); case Some(value) => value }
        if (!entry.saved && !entry.saveSent) {
            let alias = match (publication.retainConsumer()) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(value) => value }
            entry.saveAlias = Some(alias); entry.saveSent = true
            match (repository.saveOwnedFailureOutcome113(alias)) {
                case OwnedFailureDataOutcome113.Value(_) => ()
                case OwnedFailureDataOutcome113.Failure(consumer) =>
                    let _ = control.captureCheckpointFailure113(consumer, primary: false, dataOnly113: true)
                    if (alias.isAcknowledged()) { entry.saveAlias = None<OwnedFailureRunPublication113> }
                    // Input retirement is not a successful SQL write. Keep
                    // the original publication and exact pending write debt.
                    return Result.Err(coreOwnedCheckpointFailurePending113()) }
        }
        match (entry.saveAlias) { case Some(value) => if (value.isAcknowledged()) {
                entry.saveAlias = None<OwnedFailureRunPublication113>; entry.saved = true }
            case None => () }
        if (!entry.saved) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        if (!entry.appendSent) {
            let alias = match (publication.retainConsumer()) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(value) => value }
            entry.appendAlias = Some(alias); entry.appendSent = true
            match (repository.appendOwnedFailureOutcome113(alias)) {
                case OwnedFailureDataOutcome113.Value(_) => ()
                case OwnedFailureDataOutcome113.Failure(consumer) =>
                    let _ = control.captureCheckpointFailure113(consumer, primary: false, dataOnly113: true)
                    if (alias.isAcknowledged()) { entry.appendAlias = None<OwnedFailureRunPublication113> }
                    return Result.Err(coreOwnedCheckpointFailurePending113()) }
        }
        match (entry.appendAlias) { case Some(value) => if (value.isAcknowledged()) {
                entry.appendAlias = None<OwnedFailureRunPublication113>; entry.appended = true }
            case None => () }
        if (!entry.appended) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        if (!entry.eventSent) {
            let sink = match (events) { case None => return Result.Err(coreOwnedCheckpointFailurePending113())
                case Some(value) => match (value as OwnedFailureEventSink113) {
                    case None => return Result.Err(coreOwnedCheckpointFailurePending113()); case Some(target) => target } }
            let alias = match (publication.retainConsumer()) {
                case Result.Err(_) => return Result.Err(coreOwnedCheckpointFailurePending113()); case Result.Ok(value) => value }
            entry.eventAlias = Some(alias); entry.eventSent = true
            match (sink.emitOwnedFailureOutcome113(alias)) {
                case OwnedFailureDataOutcome113.Value(_) => entry.eventAccepted113 = true
                case OwnedFailureDataOutcome113.Failure(consumer) =>
                    let _ = control.captureCheckpointFailure113(consumer, primary: false, dataOnly113: true)
                    if (alias.isAcknowledged()) { entry.eventAlias = None<OwnedFailureRunPublication113> }
                    return Result.Err(coreOwnedCheckpointFailurePending113()) }
        }
        match (entry.eventAlias) { case Some(value) => if (value.isAcknowledged()) {
                entry.eventAlias = None<OwnedFailureRunPublication113>; entry.delivered = true }
            case None => () }
        if (!entry.delivered) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        Result<Unit>.Ok(())
    }
    private func deliverCheckpointFailureQueue113(control: CoreRunControl,
        events: ?OwnedAgentEventSink): Result<Unit> {
        var selected = control.checkpointFailureHead113()
        while (selected.isSome()) {
            let entry = selected.getOrThrow()
            if (!entry.beginWork()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
            try {
                if (entry.publication.isNone()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
                match (deliverCheckpointPublication113(entry, control, events)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            } catch (_: Exception) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
            finally { entry.endWork() }
            selected = entry.next
        }
        Result<Unit>.Ok(())
    }
    // This DATA retry/poll uses already paid metadata and the same actual
    // ordered event lock. It never rebuilds a Source or repeats a tool hook.
    public func flushOwnedCheckpointFailures113(run: RunId,
        events!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>): Result<Unit> {
        let control = match (controls.find(run)) { case None => return Result<Unit>.Ok(()); case Some(value) => value }
        if (!control.hasCheckpointFailure113()) { return Result<Unit>.Ok(()) }
        // A typed observer may inspect/poll reentrantly. Its current Unit
        // consumer must return before the ordered event lock is reacquired.
        if (control.hasCheckpointConsumerFrame113()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        let delivered = control.serializeEvent({ => deliverCheckpointFailureQueue113(control, events) })
        let retired = control.retireCheckpointFailures113()
        if (!control.hasCheckpointFailure113()) { finishControl(run) }
        match (delivered) { case Result.Err(error) => Result<Unit>.Err(error); case Result.Ok(_) => retired }
    }
    private func publishCheckpointFailures113(request: AgentRunRequest, context: ToolInvocationContext,
        control: CoreRunControl, counter: ?BudgetCounter, ownsRunFailure: Bool): Result<Unit> {
        let status = control.state()
        if (status != RunState.Failed && status != RunState.Cancelled && status != RunState.RecoveryRequired) {
            return Result.Err(coreOwnedCheckpointFailurePending113()) }
        control.serializeEvent({ =>
            // Install the complete paid metadata for every actual failure
            // before IO. Pending IO for the first cannot hide a later caller.
            var selected = control.checkpointFailureHead113()
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (!entry.beginWork()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
                try {
                    match (prepareCheckpointPublication113(entry, request, context, control, counter, status, ownsRunFailure)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                } catch (_: Exception) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
                finally { entry.endWork() }
                selected = entry.next
            }
            deliverCheckpointFailureQueue113(control, request.ownedEvents)
        })
    }

    private func fail(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        control: CoreRunControl,
        error: AgentError,
        sink: AgentEventSink,
        counter!: ?BudgetCounter = None
    ): Result<AgentRunOutcome> {
        if (control.isCheckpointFailureMarker113(error)) {
            return failOwnedCheckpointFailure113(request, context, control, sink, counter) }
        if(control.outerErrorData333().isSome()){
            match(control.outerErrorSource333()){
                case Some(source)=>return failOwnedOuterError333(request,context,control,source,sink,counter)
                case None=>return Result.Err(coreOwnedOuterErrorPending333())}}
        let terminalState = if (error.kind == AgentErrorKind.RecoveryRequired) {
            RunState.RecoveryRequired
        } else {
            RunState.Failed
        }
        if (!isTerminalRunState(control.state())) {
            if (error.kind == AgentErrorKind.Cancelled) {
                let reason = CancellationReason(
                    CancellationReasonKind.User,
                    error.code,
                    error.message,
                    cancelledAtMillis: agentUtcMillis()
                )
                let _ = control.requestCancel(
                    CancellationReasonKind.User, error.code, error.message
                )
                match (control.settleCancellation(reason)) {
                    case Result.Ok(transitions) => for (value in transitions) {
                        let _ = emitTransition(context, control, value, sink)
                    }
                    case Result.Err(_) => ()
                }
            } else {
                match (control.finish(terminalState, reason: error.code)) {
                    case Result.Ok(value) => let _ = emitTransition(context, control, value, sink)
                    case Result.Err(_) => ()
                }
            }
        }
        let modelRequests = match (counter) {
            case Some(value) => value.modelRequests
            case None => 0
        }
        let usage = match (counter) {
            case Some(value) => value.usage()
            case None => ModelUsage()
        }
        let lastInputTokens = match (counter) {
            case Some(value) => value.lastInputTokens
            case None => 0
        }
        let lastOutputTokens = match (counter) {
            case Some(value) => value.lastOutputTokens
            case None => 0
        }
        let lastRequestDurationMillis = match (counter) {
            case Some(value) => value.lastRequestDurationMillis
            case None => 0
        }
        let toolCalls = match (counter) {
            case Some(value) => value.toolCalls
            case None => 0
        }
        let turns = match (counter) {
            case Some(value) => value.turns
            case None => 0
        }
        let snapshot = RunSnapshot(
            request.runId,
            request.sessionId,
            if (control.state() == RunState.RecoveryRequired) {
                RunState.RecoveryRequired
            } else { match (error.kind) {
                case AgentErrorKind.Cancelled => RunState.Cancelled
                case AgentErrorKind.RecoveryRequired => RunState.RecoveryRequired
                case _ => RunState.Failed
            } },
            sequence: context.currentSequence(),
            summary: error.message,
            modelRequests: modelRequests,
            usage: usage,
            lastInputTokens: lastInputTokens,
            lastOutputTokens: lastOutputTokens,
            lastRequestDurationMillis: lastRequestDurationMillis,
            toolCalls: toolCalls,
            turns: turns,
            error: Some(error)
        )
        let _ = runs.save(snapshot)
        let _ = emitTyped(
            context,
            control,
            AgentEventPayload.Diagnostic(error),
            sink
        )
        if (control.hasCheckpointFailure113()) {
            let _ = publishCheckpointFailures113(request, context, control, counter, false) }
        finishControl(request.runId)
        Result.Err(error)
    }

    private func fail(
        request: AgentRunRequest,
        context: ToolInvocationContext,
        error: AgentError,
        sink: AgentEventSink,
        counter!: ?BudgetCounter = None
    ): Result<AgentRunOutcome> {
        match (controls.find(request.runId)) {
            case Some(control) => fail(
                request,
                context,
                control,
                error,
                sink,
                counter: counter
            )
            case None =>
                let runtime = match (threadRuntimes.acquire(
                    ThreadId(request.sessionId.value), coreWorkspaceId(request)
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => return Result.Err(error)
                }
                let control = CoreRunControl(
                    request.runId,
                    request.budget,
                    runtime,
                    initial: RunState.Running, callerCancellation180: request.callerCancellation180,
                    recoveryPolicy180: modelAttemptRecoveryForSettings180(request.toolContext.executionSettings180, modelAttemptRecovery)
                )
                if (!runtime.hasActiveRun159()) {
                    // An already described continuation cannot be recreated as
                    // an ordinary user Turn merely because its control ended.
                    for (item in runtime.threadSnapshot().items where isContinuationInitiatorDescription(item)) {
                        if (item.provenance.runId.getOrThrow().value == request.runId.value) { control.close(); return Result.Err(error) }
                    }
                    match (runtime.startTurn(
                        SemanticTurnId("turn-" + request.runId.value), request.runId,
                        match (request.queuedInitiator113) { case Some(value) => ItemId(value.entryId.value); case None => ItemId("user-" + request.runId.value) },
                        coreUserContent(ModelMessage(
                            ModelRole.User,
                            [ModelBlock(ModelBlockKind.Text, text: request.prompt)]
                        )),
                        coreModelLane(request, catalog), request.contextSnapshot,
                        executionLaneId: request.executionLaneId,
                        createdAtMillis: agentUtcMillis(),
                        deadlineMillis: request.budget.deadlineMillis,
                        parentCancellation: Some(control.source.token),
                        runBudgetSnapshot: coreBudgetSnapshot(request.budget),
                        queuedInitiator113: request.queuedInitiator113, queuedInputPayment113: request.queuedInputPayment113
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(_) => control.close(); return Result.Err(error)
                    }
                }
                match (control.bindRuntimeCancellation(coreOwnedControlMetadata(runtime).activeEpoch)) {
                    case Result.Err(_) => control.close(); return Result.Err(error)
                    case Result.Ok(_) => ()
                }
                try { fail(
                    request,
                    context,
                    control,
                    error,
                    sink,
                    counter: counter
                ) } finally { control.close() }
        }
    }

    private func cancelPendingApproval(
        control: CoreRunControl,
        snapshot: RunSnapshot,
        cancelContext: ToolInvocationContext
    ): Result<Unit> {
        let continuation = match (runs.continuation(snapshot.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let approval = continuation.approval
        let plan = match (operationRuntime.loadPlan(
            approval.operationId, snapshot.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (approval.toolName == HOST_CONTEXT_READ_TOOL) {
            let pending = match (control.pendingRead(approval.operationId)) {
                case Some(value) => value
                case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "context.read_live_owner_missing", "cancel cannot reconstruct a historical preparation source")) }
            if (!pending.claim()) { return Result.Err(AgentError(AgentErrorKind.Conflict,
                "context.read_already_resuming", "another owner is settling this read")) }
            match (control.beginCancellationSettlement(pending.epoch)) {
                case Result.Err(error) => pending.releaseUnstartedClaim(); return Result.Err(error)
                case Result.Ok(_) => ()
            }
            // Reuse the cancellation command's actual event-head counter. The
            // approval snapshot predates its approval/transition events.
            let readContext = cancelContext
            let settled = try { settleContextRead(readContext, control, pending.owner, pending.prepared,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled,
                    "operation.cancelled_before_execution", "pending preparation read was cancelled")), false) }
                finally {
                    control.releasePendingRead(approval.operationId)
                    let _ = releaseContextReadSlot(readContext, control, approval.operationId, { _ => () })
                }
            match (settled) {
                case Result.Err(error) =>
                    let _ = control.finish(RunState.RecoveryRequired, reason: "context.read_cancel_settlement_failed")
                    return Result.Err(error)
                case Result.Ok(_) => ()
            }
            let parents = match (pendingCommittedToolCalls(control)) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    let _ = control.finish(RunState.RecoveryRequired, reason: "context.read_parent_cancel_source_failed")
                    return Result.Err(error)
            }
            for (parent in parents) {
                match (appendSkippedToolCall(snapshot.sessionId, readContext, control, parent, { _ => () },
                    errorCode: "tool.cancelled_during_preparation", message: "preparation read was cancelled before this tool could execute",
                    cancellationSettlement: true)) {
                    case Result.Err(error) =>
                        let _ = control.finish(RunState.RecoveryRequired, reason: "context.read_parent_cancel_settlement_failed")
                        return Result.Err(error)
                    case Result.Ok(_) => control.releasePreparationInput(parent.canonicalItemId) }
            }
            return Result.Ok(())
        }
        let committed = match (committedToolCallFor(control, approval.callId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (control.beginCancellationSettlement(cancelContext.epoch)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (commitCanonicalToolAttempt(
            control,
            CoreToolOutcome(
                0,
                committed,
                Result.Ok(ToolInvocationResult.Denied(ToolDenial(
                    committed.block.callId, committed.block.name, AgentError(
                        AgentErrorKind.Cancelled,
                        "operation.cancelled_before_execution",
                        "pending Operation was cancelled before execution"
                    )
                ))),
                operationId: Some(approval.operationId),
                operationPlan: Some(plan),
                attemptStage: OperationAttemptStage.Prepared
            )
        )) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        // start() registers the single-owner control before it persists the
        // compatibility RunSnapshot. Cancellation must remain effective in
        // that narrow admission window instead of treating the not-yet-written
        // snapshot as durable corruption. The active worker owns settlement.
        match (controls.find(runId)) {
            case Some(control) =>
                if (!isAwaitingApproval(control.state())) {
                    let _ = control.requestCancel(
                        CancellationReasonKind.User,
                        "run.cancelled",
                        "execution was cancelled by the user"
                    )
                    // Signal executors immediately. The cancellation token
                    // callback is asynchronous; managed jobs have a distinct
                    // process operation and cannot wait for that callback.
                    let _ = tools.cancel(runId, threadId: Some(coreOwnedControlMetadata(control.runtime).thread.id))
                    for (_ in 0..100) {
                        let terminal = match (runs.find(runId)) {
                            case Result.Ok(value) => isTerminalRunState(value.status)
                            case Result.Err(_) => isTerminalRunState(control.state())
                        }
                        if (terminal) {
                            return Result.Ok(())
                        }
                        sleep(Duration.millisecond * 10)
                    }
                    return Result.Ok(())
                }
            case None => ()
        }
        let previous = match (runs.find(runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let cancelSequence = match (runs.events(runId, previous.sequence)) {
            case Result.Ok(page) => max(previous.sequence, page.nextSequence - 1)
            case Result.Err(error) => return Result.Err(error)
        }
        let cancelContext = match (controls.find(runId)) {
            case Some(control) => ToolInvocationContext(
                previous.runId, previous.sessionId, CapabilitySet(),
                sequence: cancelSequence, epoch: coreOwnedControlMetadata(control.runtime).activeEpoch,
                cancellation: control.source.token, budget: control.ledger)
            case None => ToolInvocationContext(
                previous.runId, previous.sessionId, CapabilitySet(), sequence: cancelSequence)
        }
        match (controls.find(runId)) {
            case Some(control) =>
                let _ = control.requestCancel(
                    CancellationReasonKind.User,
                    "run.cancelled",
                    "execution was cancelled by the user"
                )
                if (!isAwaitingApproval(previous.status)) {
                    // The active execution worker owns ToolResult and terminal
                    // Run settlement. The command path only signals cancel and
                    // waits boundedly; racing it would close the Run before the
                    // canonical tool protocol is complete.
                    for (_ in 0..100) {
                        let terminal = match (runs.find(runId)) {
                            case Result.Ok(value) => isTerminalRunState(value.status)
                            case Result.Err(_) => isTerminalRunState(control.state())
                        }
                        if (terminal) { return Result.Ok(()) }
                        sleep(Duration.millisecond * 10)
                    }
                    return Result.Ok(())
                }
            case None =>
                match (model.cancel(runId.value)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                match (tools.cancel(runId, threadId: Some(ThreadId(previous.sessionId.value)))) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
        }
        var terminalEventError: ?AgentError = None
        match (controls.find(runId)) {
            case Some(control) =>
                if (isAwaitingApproval(previous.status) &&
                    isAwaitingApproval(control.state())) {
                    match (cancelPendingApproval(control, previous, cancelContext)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
                }
                if (!isTerminalRunState(control.state())) {
                    let reason = CancellationReason(
                        CancellationReasonKind.User,
                        "run.cancelled",
                        "execution was cancelled by the user",
                        cancelledAtMillis: agentUtcMillis()
                    )
                    match (control.settleCancellation(reason)) {
                        case Result.Ok(transitions) => for (value in transitions) {
                            match (emitTransition(cancelContext, control, value, {_ => ()})) {
                                case Result.Ok(_) => ()
                                case Result.Err(error) => if (terminalEventError.isNone()) {
                                    terminalEventError = Some(error)
                                }
                            }
                        }
                        case Result.Err(error) => return Result.Err(error)
                    }
                }
            case None => ()
        }
        // The canonical Run and resources have settled. Still attempt the
        // product snapshot and dispose registrations if terminal publication
        // failed, then report that first error instead of claiming success.
        let saved = runs.save(
            RunSnapshot(
                previous.runId,
                previous.sessionId,
                RunState.Cancelled,
                sequence: cancelContext.currentSequence(),
                summary: "run cancelled",
                modelRequests: previous.modelRequests,
                usage: previous.usage,
                lastInputTokens: previous.lastInputTokens,
                lastOutputTokens: previous.lastOutputTokens,
                lastRequestDurationMillis: previous.lastRequestDurationMillis,
                toolCalls: previous.toolCalls,
                turns: previous.turns,
                kind: previous.kind
            )
        )
        finishControl(runId)
        match (terminalEventError) {
            case Some(error) => Result.Err(error)
            case None => saved
        }
    }

    private func borrowRequestTools159(value: ModelRequest): ?ModelInputToolsBorrow159 {
        match (value.inputToolsLifetime159) { case Some(owner) => Some(owner.borrowModelTools159()); case None => None<ModelInputToolsBorrow159> }
    }
    private func ownedModelTranscript159(value: ModelRequest): ?String {
        let loan = borrowRequestTools159(value)
        match (loan) {
            case Some(input) => match (model) {
                case actual: ReturningModelTranscriptPort159 => actual.transcriptSnapshotReturning159(value, input)
                case _ => model.transcriptSnapshot(value)
            }
            case None => model.transcriptSnapshot(value)
        }
    }
    private func createOwnedModelAttempt159(attempt: DurableModelAttempt, modelInput: ModelRequest): Result<Unit> {
        let loan = borrowRequestTools159(modelInput)
        match (loan) {
            case Some(input) => match (modelDecisionRuntime) {
                case actual: ReturningModelDecisionRuntime159 => actual.createAttemptReturning159(attempt, input)
                case _ => modelDecisionRuntime.createAttempt(attempt)
            }
            case None => modelDecisionRuntime.createAttempt(attempt)
        }
    }
    private func prepareOwnedAttempt159(modelInput: ModelRequest, attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        let loan = borrowRequestTools159(modelInput)
        match (loan) {
            case Some(input) => match (runs) {
                case actual: ReturningModelAttemptRepository159 => actual.prepareModelAttemptReturning159(input, attempt, event, continuation)
                case _ => runs.prepareModelAttempt(attempt, event, continuation)
            }
            case None => runs.prepareModelAttempt(attempt, event, continuation)
        }
    }
    private func prepareOwnedBoundaryAttempt159(modelInput: ModelRequest, expected: RunContextBoundary, attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        let loan = borrowRequestTools159(modelInput)
        match (loan) {
            case Some(input) => match (runs) {
                case actual: ReturningModelAttemptRepository159 => actual.prepareContextBoundaryModelAttemptReturning159(input, expected, attempt, event, continuation)
                case _ => runs.prepareContextBoundaryModelAttempt(expected, attempt, event, continuation)
            }
            case None => runs.prepareContextBoundaryModelAttempt(expected, attempt, event, continuation)
        }
    }
    private func prepareOwnedRestartAttempt159(modelInput: ModelRequest, parent: DurableModelAttempt, attempt: DurableModelAttempt, policyEvent: AgentEvent, duplicateEvent: AgentEvent, continuation: RunContinuation): Result<Unit> {
        let loan = borrowRequestTools159(modelInput)
        match (loan) {
            case Some(input) => match (runs) {
                case actual: ReturningModelAttemptRepository159 => actual.prepareRestartModelAttemptReturning159(input, parent, attempt, policyEvent, duplicateEvent, continuation)
                case _ => runs.prepareRestartModelAttempt(parent, attempt, policyEvent, duplicateEvent, continuation)
            }
            case None => runs.prepareRestartModelAttempt(parent, attempt, policyEvent, duplicateEvent, continuation)
        }
    }

    private func persistModelAttemptBeforeRequest(
        request: AgentRunRequest,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        attemptNo: Int64,
        parentAttemptId: ?ModelAttemptId,
        policy: AttemptPolicy,
        effectiveRequest: ModelRequest,
        counter: BudgetCounter,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink,
        toolLoopState: CoreToolLoopState,
        restartParent!: ?DurableModelAttempt = None
    ): Result<Unit> {
        // The same Run owns cleanup debt across retries and provider fallback.
        // This runs before creating/claiming another Attempt; current admitted
        // Attempt callbacks do not re-enter this model boundary.
        match (control.runtime.requireModelBoundary(context.runId, context.epoch)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let now = agentUtcMillis()
        // Prepared owns construction. Each actual receiver admits its own
        // loan at dispatch, so a branch which never calls it has no orphan loan.
        let canonicalRequest = modelRequestCheckpointValue(effectiveRequest)
        let semanticRequestDigest = canonicalAgentValueSha256(canonicalRequest)
        let wirePolicyDigest = modelRequestWirePolicyDigest(effectiveRequest)
        let attempt = DurableModelAttempt(
            attemptId,
            semanticRequestId,
            request.runId,
            attemptNo,
            ModelAttemptLifecycle.Created,
            attemptPolicyValue(policy),
            attemptPolicyReasonName(policy.reason),
            now,
            now,
            parentAttemptId: parentAttemptId,
            providerRequestId: effectiveRequest.requestId,
            semanticRequestDigest: semanticRequestDigest,
            wirePolicyDigest: wirePolicyDigest,
            transcriptSnapshot: match (ownedModelTranscript159(effectiveRequest)) {
                case Some(value) => value
                case None => ""
            },
            dispatchState: ModelAttemptDispatchState.Prepared,
            replayBarrier: ModelAttemptReplayBarrier.NoBarrier
        )
        let values = [
            ValueField("code", textValue("model.attempt_policy_applied")),
            ValueField("semantic_request_id", textValue(semanticRequestId.value)),
            ValueField("attempt_id", textValue(attemptId.value)),
            ValueField("policy_reason", textValue(attemptPolicyReasonName(policy.reason))),
            ValueField("policy", attemptPolicyValue(policy))
        ]
        let event = AgentEvent(
            EventMeta(
                context.nextSequence(),
                control.traceId,
                context.runId,
                occurredAtMillis: now,
                turnId: control.currentTurnId(),
                requestId: match (control.currentRequestId()) {
                    case "" => None
                    case value => Some(RequestId(value))
                },
                semanticRequestId: Some(semanticRequestId),
                attemptId: Some(attemptId),
                toolBatchId: control.currentBatchId()
            ),
            AgentEventPayload.Extension(
                AgentEventKind.Audit,
                objectValue(values)
            )
        )
        let checkpoint = RunningModelCheckpoint(
            semanticRequestId,
            canonicalRequest,
            semanticRequestDigest,
            wirePolicyDigest,
            modelAttemptIdFor(semanticRequestId, 1),
            attemptId,
            match (control.currentTurnId()) {
                case Some(value) => value.value
                case None => "turn-" + request.runId.value
            },
            effectiveRequest.requestId,
            now,
            modelRequests: counter.modelRequests,
            workModelRequests: counter.workModelRequests,
            drainModelRequests: counter.drainModelRequests,
            requestBudgetClass: if (control.budgetMode() == BudgetMode.Draining) {
                BudgetChargeClass.Drain
            } else {
                BudgetChargeClass.Work
            },
            inputTokens: counter.inputTokens,
            outputTokens: counter.outputTokens,
            reasoningTokens: counter.reasoningTokens,
            cacheReadTokens: counter.cacheReadTokens,
            cacheWriteTokens: counter.cacheWriteTokens,
            costMicros: counter.costMicros,
            lastInputTokens: counter.lastInputTokens,
            lastOutputTokens: counter.lastOutputTokens,
            lastRequestDurationMillis: counter.lastRequestDurationMillis,
            toolCalls: counter.toolCalls,
            turns: counter.turns,
            consecutiveCapabilityDenials: toolLoopState.consecutiveCapabilityDenials,
            lastCapabilityDeniedTool: toolLoopState.lastCapabilityDeniedTool
        )
        let continuation = RunContinuation(
            RunContinuationKind.RunningModel,
            request.runId,
            request.sessionId,
            request.model,
            request.prompt,
            checkpoint,
            request.requestedPolicy,
            request.modelCapabilitiesSnapshot,
            system: request.system,
            thinking: request.thinking,
            capabilities: request.capabilities,
            budget: request.budget,
            approvalMode: approvalModeName(request.approvalModeOverride),
            autoRetry: request.autoRetry,
            serviceTier: request.serviceTier,
            pricing: request.pricing,
            imageInputs: request.imageInputs,
            structuredOutput: request.structuredOutput,
            cachePolicy: request.cachePolicy,
            cacheKey: request.cacheKey,
            parallelToolCalls: request.parallelToolCalls,
            resolverVersion: request.resolverVersion,
            contextSnapshotPayload: contextSnapshotValue(request.contextSnapshot),
            contextWindow: request.contextWindow,
            providerSafetyMargin: request.providerSafetyMargin,
            toolContextPayload: toolContextDescriptorValue(request.toolContext),
            executionLaneId: request.executionLaneId
        )
        let restartEvent: ?AgentEvent = match (restartParent) {
            case Some(parent) => Some(AgentEvent(
                EventMeta(
                    context.nextSequence(), control.traceId, context.runId,
                    occurredAtMillis: now, turnId: control.currentTurnId(),
                    requestId: match (control.currentRequestId()) {
                        case "" => None
                        case value => Some(RequestId(value))
                    },
                    semanticRequestId: Some(semanticRequestId),
                    attemptId: Some(attemptId),
                    toolBatchId: control.currentBatchId()
                ),
                AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                    ValueField("code", textValue("model.restart_retry_possible_duplicate")),
                    ValueField("semantic_request_id", textValue(semanticRequestId.value)),
                    ValueField("attempt_id", textValue(attemptId.value)),
                    ValueField("parent_attempt_id", textValue(parent.id.value))
                ]))
            ))
            case None => None
        }
        match ((restartParent, restartEvent)) {
            case (Some(parent), Some(duplicateEvent)) => match (
                prepareOwnedRestartAttempt159(effectiveRequest,
                    parent, attempt, event, duplicateEvent, continuation
                )
            ) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            case (None, None) => match (                match (runs.contextBoundary(request.runId)) {
                    case Result.Ok(Some(boundary)) => prepareOwnedBoundaryAttempt159(effectiveRequest, boundary, attempt, event, continuation)
                    case Result.Ok(None) => if (control.contextBoundaryPrepareRequired()) {
                        Result<Unit>.Err(coreContextBoundaryError("current context boundary was replaced before its fresh Attempt"))
                    } else { prepareOwnedAttempt159(effectiveRequest, attempt, event, continuation) }
                    case Result.Err(error) => Result<Unit>.Err(error) }) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            case _ => return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "model.restart_boundary_invalid",
                "restart model Attempt boundary is incomplete"
            ))
        }
        control.didPrepareContextBoundary()
        // SQLite sees the same row and validates it idempotently. Ephemeral
        // runtimes mirror the already committed policy for lifecycle methods.
        match (restartParent) {
            case Some(parent) => match (modelDecisionRuntime.terminalizeAttempt(
                parent.id,
                ModelAttemptLifecycle.Abandoned,
                "process_restart_possible_duplicate",
                now
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            case None => ()
        }
        match (createOwnedModelAttempt159(attempt, effectiveRequest)) {
            case Result.Ok(_) =>
                sink(event)
                match (restartEvent) {
                    case Some(value) => sink(value)
                    case None => ()
                }
                Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func claimModelAttemptBeforeRequest(
        attemptId: ModelAttemptId,
        semanticRequestId: SemanticModelRequestId,
        context: ToolInvocationContext,
        control: CoreRunControl,
        sink: AgentEventSink
    ): Result<Unit> {
        // The same Run owns cleanup debt across retries and provider fallback.
        // This runs before creating/claiming another Attempt; current admitted
        // Attempt callbacks do not re-enter this model boundary.
        match (control.runtime.requireModelBoundary(context.runId, context.epoch)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let now = agentUtcMillis()
        let event = AgentEvent(
            EventMeta(
                context.nextSequence(), control.traceId, context.runId,
                occurredAtMillis: now, turnId: control.currentTurnId(),
                requestId: match (control.currentRequestId()) {
                    case "" => None
                    case value => Some(RequestId(value))
                },
                semanticRequestId: Some(semanticRequestId),
                attemptId: Some(attemptId), toolBatchId: control.currentBatchId()
            ),
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                ValueField("code", textValue("model.attempt_dispatch_claimed")),
                ValueField("semantic_request_id", textValue(semanticRequestId.value)),
                ValueField("attempt_id", textValue(attemptId.value))
            ]))
        )
        match (runs.claimModelAttemptDispatch(attemptId, event)) {
            case Result.Ok(true) => sink(event); Result.Ok(())
            case Result.Ok(false) => Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.attempt_already_dispatched",
                "model Attempt dispatch was already claimed; automatic replay is unsafe",
                fields: [ErrorField("attempt_id", attemptId.value)]
            ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func durableResultForAttempt(
        request: AgentRunRequest,
        semanticRequestId: SemanticModelRequestId,
        attemptId: ModelAttemptId,
        result: Result<ModelReply>,
        terminalizeFailure!: Bool = true
    ): Result<DurableModelResult> {
        match (result) {
            case Result.Err(error) =>
                if (!terminalizeFailure) { return Result.Err(error) }
                match (modelDecisionRuntime.terminalizeAttempt(
                    attemptId,
                    if (error.kind == AgentErrorKind.Cancelled) {
                        ModelAttemptLifecycle.Cancelled
                    } else { ModelAttemptLifecycle.Failed },
                    match (error.attemptFailure) {
                        case Some(value) => attemptFailureKindName(value.kind)
                        case None => error.code
                    },
                    agentUtcMillis()
                )) {
                    case Result.Ok(_) => Result.Err(error)
                    case Result.Err(storeError) => Result.Err(storeError)
                }
            case Result.Ok(reply) =>
                let decision = match (validatedModelDecision(
                    semanticRequestId, attemptId, reply
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) =>
                        if (!terminalizeFailure) { return Result.Err(error) }
                        let _ = modelDecisionRuntime.terminalizeAttempt(
                            attemptId, ModelAttemptLifecycle.Failed,
                            match (error.attemptFailure) {
                                case Some(value) => attemptFailureKindName(value.kind)
                                case None => error.code
                            }, agentUtcMillis()
                        )
                        return Result.Err(error)
                }
                match (modelDecisionRuntime.persistValidatedDecision(decision)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                match (modelDecisionRuntime.finalizeUsage(
                    decision.id, accountedModelAttemptUsage(reply, request.pricing),
                    agentUtcMillis()
                )) {
                    case Result.Ok(_) => Result.Ok(DurableModelResult(reply, decision))
                    case Result.Err(error) => Result.Err(error)
                }
        }
    }
}

func isProvisionalStreamTelemetry(event: AgentEvent): Bool {
    if (event.meta.attemptId.isNone()) { return false }
    match (event.payload) {
        case AgentEventPayload.TextDelta(_) | AgentEventPayload.ReasoningDelta(_) => true
        case AgentEventPayload.Extension(_, detail) =>
            match (detail.field("code")) {
                case Some(value) => value.unifiedKind == ValueKind.Text &&
                    value.text == "model.tool_arguments"
                case None => false
            }
        case _ => false
    }
}

func continuationFromRequest(
    request: AgentRunRequest,
    approval: ApprovalRequest
): RunContinuation {
    RunContinuation(
        request.runId,
        request.sessionId,
        request.model,
        request.prompt,
        approval,
        system: request.system,
        thinking: request.thinking,
        capabilities: request.capabilities,
        budget: request.budget,
        approvalMode: approvalModeName(request.approvalModeOverride),
        autoRetry: request.autoRetry,
        serviceTier: request.serviceTier,
        pricing: request.pricing,
        imageInputs: request.imageInputs,
        structuredOutput: request.structuredOutput,
        cachePolicy: request.cachePolicy,
        cacheKey: request.cacheKey,
        parallelToolCalls: request.parallelToolCalls,
        requestedPolicy: Some(request.requestedPolicy),
        modelCapabilitiesSnapshot: Some(request.modelCapabilitiesSnapshot),
        resolverVersion: request.resolverVersion,
        contextSnapshotPayload: contextSnapshotValue(request.contextSnapshot),
        contextWindow: request.contextWindow,
        providerSafetyMargin: request.providerSafetyMargin,
        toolContextPayload: toolContextDescriptorValue(request.toolContext),
        executionLaneId: request.executionLaneId
    )
}

func requestFromContinuation(
    value: RunContinuation,
    interactions!: ?AgentInteractionSource = None,
    toolContext!: ToolContextDescriptor = ToolContextDescriptor()
): AgentRunRequest {
    AgentRunRequest(
        value.runId,
        value.sessionId,
        value.model,
        value.prompt,
        system: value.system,
        thinking: value.thinking,
        userRequestedThinking: match (value.requestedPolicy) {
            case Some(policy) => policy.userRequestedThinking
            case None => None
        },
        thinkingSource: match (value.requestedPolicy) {
            case Some(policy) => policy.thinkingSource
            case None => ThinkingPreferenceSource.ModelDefault
        },
        modelCapabilitiesSnapshot: value.modelCapabilitiesSnapshot,
        resolverVersion: value.resolverVersion,
        capabilities: value.capabilities,
        budget: value.budget,
        interactions: interactions,
        approvalModeOverride: approvalModeFromName(value.approvalMode),
        autoRetry: value.autoRetry,
        serviceTier: value.serviceTier,
        pricing: value.pricing,
        imageInputs: value.imageInputs,
        structuredOutput: value.structuredOutput,
        cachePolicy: value.cachePolicy,
        cacheKey: value.cacheKey,
        parallelToolCalls: value.parallelToolCalls,
        toolContext: if (value.toolContextPayload.fields.isEmpty()) {
            toolContext
        } else {
            toolContextDescriptorFromValue(value.toolContextPayload)
        },
        contextSnapshot: if (value.contextSnapshotPayload.unifiedKind == ValueKind.Object && value.contextSnapshotPayload.fields.isEmpty()) {
            InvocationContextProjection()
        } else {
            contextSnapshotFromValue(value.contextSnapshotPayload)
        },
        contextWindow: value.contextWindow,
        providerSafetyMargin: value.providerSafetyMargin,
        executionLaneId: value.executionLaneId
    )
}

func approvalModeName(value: ?ApprovalMode): String {
    match (value) {
        case None => ""
        case Some(ApprovalMode.AlwaysAsk) => "always_ask"
        case Some(ApprovalMode.Write) => "write"
        case Some(ApprovalMode.Yolo) => "yolo"
    }
}

func approvalModeFromName(value: String): ?ApprovalMode {
    match (value) {
        case "always_ask" => Some(ApprovalMode.AlwaysAsk)
        case "write" => Some(ApprovalMode.Write)
        case "yolo" => Some(ApprovalMode.Yolo)
        case _ => None
    }
}

func toolContextDescriptorValue(value: ToolContextDescriptor): AgentValue {
    let environment = ArrayList<AgentValue>()
    for (entry in value.environment.entries()) {
        environment.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("value", textValue(entry.value))
        ]))
    }
    let services = ArrayList<AgentValue>()
    for (service in value.services.descriptors()) {
        services.add(objectValue([
            ValueField("kind", textValue(toolServiceKindName(service.kind))),
            ValueField("name", textValue(service.name)),
            ValueField("version", textValue(service.version))
        ]))
    }
    let fields = ArrayList<ValueField>([
        ValueField("workspace_root", textValue(value.workspaceRoot)),
        ValueField("cwd", textValue(value.cwd)),
        ValueField("environment", listValue(environment.toArray())),
        ValueField("services", listValue(services.toArray()))])
    if (value.executionSettings180.unifiedKind != ValueKind.Null) { fields.add(ValueField("execution_settings", value.executionSettings180)) }
    objectValue(fields.toArray())
}

func toolContextDescriptorFromValue(value: AgentValue): ToolContextDescriptor {
    let environment = ArrayList<ToolEnvironmentEntry>()
    for (entry in requiredCoreListField(value, "environment")) {
        environment.add(ToolEnvironmentEntry(
            requiredCoreTextField(entry, "name"),
            requiredCoreTextField(entry, "value")
        ))
    }
    let services = ArrayList<ToolServiceDescriptor>()
    for (service in requiredCoreListField(value, "services")) {
        services.add(ToolServiceDescriptor(
            toolServiceKindFromName(requiredCoreTextField(service, "kind")),
            requiredCoreTextField(service, "name"),
            version: requiredCoreTextField(service, "version")
        ))
    }
    ToolContextDescriptor(
        workspaceRoot: requiredCoreTextField(value, "workspace_root"),
        cwd: requiredCoreTextField(value, "cwd"),
        environment: ToolEnvironmentView(entries: environment.toArray()),
        services: ToolServiceView(descriptors: services.toArray()),
        executionSettings180: value.field("execution_settings").getOrDefault({ => nullValue() })
    )
}

func toolServiceKindName(value: ToolServiceKind): String {
    match (value) {
        case ToolServiceKind.Workspace => "workspace"
        case ToolServiceKind.Process => "process"
        case ToolServiceKind.Conversation => "conversation"
        case ToolServiceKind.Artifact => "artifact"
        case ToolServiceKind.Memory => "memory"
        case ToolServiceKind.Task => "task"
        case ToolServiceKind.Extension => "extension"
        case ToolServiceKind.Custom => "custom"
    }
}

func toolServiceKindFromName(value: String): ToolServiceKind {
    match (value) {
        case "workspace" => ToolServiceKind.Workspace
        case "process" => ToolServiceKind.Process
        case "conversation" => ToolServiceKind.Conversation
        case "artifact" => ToolServiceKind.Artifact
        case "memory" => ToolServiceKind.Memory
        case "task" => ToolServiceKind.Task
        case "extension" => ToolServiceKind.Extension
        case "custom" => ToolServiceKind.Custom
        case _ => throw IllegalArgumentException("unknown durable tool service kind")
    }
}

func requiredCoreTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text }
            else { throw IllegalArgumentException("durable field is not text: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func requiredCoreListField(value: AgentValue, name: String): Array<AgentValue> {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.List) { item.items.toArray() }
            else { throw IllegalArgumentException("durable field is not a list: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func requiredCoreValueField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func requiredCoreBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Boolean) { item.asBool() }
            else { throw IllegalArgumentException("durable field is not boolean: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func requiredCoreIntegerField(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Number) { Int64.parse(item.asNumberText()) }
            else { throw IllegalArgumentException("durable field is not an integer: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func optionalCoreIntegerField(value: AgentValue, name: String): ?Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Null) { None }
            else if (item.unifiedKind == ValueKind.Number) { Some(Int64.parse(item.asNumberText())) }
            else { throw IllegalArgumentException("durable field is not an optional integer: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func optionalCoreThinkingField(value: AgentValue, name: String): ?ThinkingLevel {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Null) { None }
            else if (item.unifiedKind == ValueKind.Text) { Some(thinkingLevelFromName(item.text)) }
            else { throw IllegalArgumentException("durable field is not optional thinking: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func validateApprovalContinuation(
    request: AgentRunRequest,
    approval: ApprovalRequest,
    continuation: RunContinuation
): Result<Unit> {
    let durable = continuation.approval
    if (request.runId.value != continuation.runId.value || request.sessionId.value != continuation.sessionId.value ||
        approval.operationId.value != durable.operationId.value || approval.callId != durable.callId ||
        approval.sessionId != durable.sessionId || approval.argumentHash != durable.argumentHash ||
        durable.sessionId != continuation.sessionId.value || durable.callId == "" || durable.argumentHash == "") {
        return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "run.approval_binding_mismatch",
            "approval decision does not match the durable pending operation",
            fields: [
                ErrorField("operation_id", durable.operationId.value),
                ErrorField("run_id", continuation.runId.value),
                ErrorField("session_id", continuation.sessionId.value),
                ErrorField("call_id", durable.callId),
                ErrorField("argument_hash", durable.argumentHash)
            ]
        ))
    }
    Result.Ok(())
}

func isRejectedDecision(value: ApprovalDecision): Bool {
    match (value) {
        case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_) => true
        case _ => false
    }
}

func rejectedOutcome(
    approval: ApprovalRequest,
    decision: ApprovalDecision
): ToolInvocationResult {
    let reason = match (decision) {
        case ApprovalDecision.RejectWithReason(value) => value
        case _ => ""
    }
    ToolInvocationResult.Denied(ToolDenial(
        approval.callId,
        approval.toolName,
        AgentError(
            AgentErrorKind.PermissionDenied,
            "tool.approval_rejected",
            if (reason.trimAscii() == "") {
                "user rejected the pending tool operation"
            } else {
                "user rejected the pending tool operation: " + reason
            },
            fields: [
                ErrorField("tool", approval.toolName),
                ErrorField("reason", reason)
            ]
        )
    ))
}


func modelTimeoutError(kind: String, millis: Int64): AgentError {
    AgentError(
        AgentErrorKind.Timeout,
        "model.${kind}_timeout",
        "model stream timed out after ${millis}ms",
        retryable: true,
        fields: [
            ErrorField("timeout_kind", kind),
            ErrorField("timeout_ms", millis.toString())
        ]
    )
}

func attemptFailureError(
    kind: AttemptFailureKind,
    code: String,
    message: String,
    diagnostics: AttemptFailureDiagnostics,
    retryable!: Bool = false
): AgentError {
    AgentError(
        if (kind == AttemptFailureKind.UserCancelled) {
            AgentErrorKind.Cancelled
        } else if (kind == AttemptFailureKind.RunDeadlineExceeded) {
            AgentErrorKind.BudgetExceeded
        } else { AgentErrorKind.Timeout },
        code,
        message,
        retryable: retryable,
        fields: attemptFailureFields(diagnostics),
        attemptFailure: Some(AttemptFailure(kind, diagnostics: diagnostics))
    )
}

func attemptFailureFields(value: AttemptFailureDiagnostics): Array<ErrorField> {
    [
        ErrorField("elapsed_ms", value.elapsedMillis.toString()),
        ErrorField("soft_deadline_ms", value.softDeadlineMillis.toString()),
        ErrorField("hard_deadline_ms", value.hardDeadlineMillis.toString()),
        ErrorField("entered_completion_grace", value.enteredCompletionGrace.toString()),
        ErrorField("last_progress_kind", attemptProgressKindName(value.lastProgressKind)),
        ErrorField("last_progress_age_ms", value.lastProgressAgeMillis.toString()),
        ErrorField("provider_terminal_observed", value.providerTerminalObserved.toString()),
        ErrorField("open_content_block_count", value.openContentBlockCount.toString()),
        ErrorField("tool_calls_started", value.toolCallsStarted.toString()),
        ErrorField("tool_calls_completed", value.toolCallsCompleted.toString()),
        ErrorField("durable_decision", "false"),
        ErrorField("canonical_tool_calls", "0"),
        ErrorField("operations_dispatched", "0")
    ]
}

func attemptProgressKindName(value: AttemptProgressKind): String {
    match (value) {
        case AttemptProgressKind.NoProgress => "none"
        case AttemptProgressKind.ReasoningProgress => "reasoning"
        case AttemptProgressKind.TextProgress => "text"
        case AttemptProgressKind.ToolCallStartedProgress => "tool_call_started"
        case AttemptProgressKind.ToolArgumentProgress => "tool_arguments"
        case AttemptProgressKind.ContentBlockCompletedProgress => "content_block_completed"
        case AttemptProgressKind.ProviderTerminalProgress => "provider_terminal"
    }
}

func controlCancellationError(control: CoreRunControl): AgentError {
    match (control.source.token.reason()) {
        case Some(reason) =>
            let kind = if (reason.kind == CancellationReasonKind.Deadline ||
                reason.kind == CancellationReasonKind.Budget) {
                AgentErrorKind.BudgetExceeded
            } else {
                AgentErrorKind.Cancelled
            }
            AgentError(
                kind,
                reason.code,
                reason.message,
                fields: [
                    ErrorField("cancel_reason", reason.code),
                    ErrorField("cancelled_at_millis", reason.cancelledAtMillis.toString())
                ],
                attemptFailure: Some(AttemptFailure(
                    if (reason.kind == CancellationReasonKind.Deadline ||
                        reason.kind == CancellationReasonKind.Budget) {
                        AttemptFailureKind.RunDeadlineExceeded
                    } else { AttemptFailureKind.UserCancelled }
                ))
            )
        case None => AgentError(
            AgentErrorKind.Cancelled,
            "run.cancelled",
            "agent run was cancelled",
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.UserCancelled))
        )
    }
}

// A retry can turn the original provider failure into a secondary closed-
// transport symptom. Preserve the actionable timeout/rate-limit cause instead
// of reporting the cleanup artifact from the final attempt.
func representativeModelRetryError(
    origin: ?AgentError,
    current: AgentError
): AgentError {
    match (origin) {
        case Some(value) =>
            if (current.kind == AgentErrorKind.Transport &&
                (value.kind == AgentErrorKind.Timeout ||
                    value.kind == AgentErrorKind.RateLimited)) {
                value
            } else {
                current
            }
        case None => current
    }
}

func outputLimitedExhaustedError(
    error: AgentError,
    attempts: Int64,
    request: ModelRequest,
    attemptId: ModelAttemptId
): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields where field.name != "recovery_attempts") {
        fields.add(field)
    }
    if (!errorHasField(error, "provider_model")) {
        fields.add(ErrorField("provider_model", request.model))
    }
    match (request.resolvedPolicy) {
        case Some(policy) =>
            fields.add(ErrorField(
                "effective_wire_output_tokens",
                policy.output.effectiveWireLimit.toString()
            ))
            fields.add(ErrorField(
                "effective_thinking_level",
                thinkingLevelName(policy.thinking.effective)
            ))
        case None => ()
    }
    if (attempts > 1 && !errorHasField(error, "parent_attempt_id")) {
        fields.add(ErrorField(
            "parent_attempt_id",
            attemptId.value.removeSuffix("-attempt-" + attempts.toString()) +
                "-attempt-" + (attempts - 1).toString()
        ))
    }
    fields.add(ErrorField("recovery_attempts", max(0, attempts - 1).toString()))
    AgentError(
        error.kind,
        "model.output_limited_before_decision",
        "model exhausted the output budget before an accepted decision boundary",
        retryable: false,
        fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray(),
        attemptFailure: Some(AttemptFailure(
            AttemptFailureKind.OutputLimitedBeforeDecision,
            diagnostics: match (error.attemptFailure) {
                case Some(value) => value.diagnostics
                case None => AttemptFailureDiagnostics()
            }
        ))
    )
}

func errorHasField(error: AgentError, name: String): Bool {
    for (field in error.fields where field.name == name) { return true }
    false
}


func attemptPolicyValue(policy: AttemptPolicy): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("model", textValue(policy.model)))
    fields.add(ValueField("thinking", textValue(thinkingLevelName(policy.thinking))))
    fields.add(ValueField("tool_choice", textValue(modelToolChoiceName(policy.toolChoice))))
    fields.add(ValueField("max_output_tokens", integerValue(policy.maxOutputTokens)))
    fields.add(ValueField("reason", textValue(attemptPolicyReasonName(policy.reason))))
    fields.add(ValueField("soft_deadline_ms", integerValue(policy.softDeadlineMillis)))
    fields.add(ValueField("hard_deadline_ms", integerValue(policy.hardDeadlineMillis)))
    fields.add(ValueField("stream_idle_ms", integerValue(policy.streamIdleMillis)))
    match (policy.resolvedPolicy) {
        case Some(value) =>
            fields.add(ValueField(
                "policy_resolution_version",
                integerValue(Int64(value.policyResolutionVersion))
            ))
            fields.add(ValueField(
                "capability_snapshot_version",
                integerValue(Int64(value.capabilitySnapshotVersion))
            ))
            fields.add(ValueField(
                "capability_fingerprint", textValue(value.capabilityFingerprint)
            ))
            fields.add(ValueField(
                "capability_snapshot_payload", textValue(value.capabilitySnapshotPayload)
            ))
            fields.add(ValueField(
                "min_visible_response_tokens", integerValue(value.minVisibleResponseTokens)
            ))
            fields.add(ValueField(
                "thinking_source", textValue(thinkingPreferenceSourceName(value.thinkingSource))
            ))
            match (value.userRequestedThinking) {
                case Some(level) => fields.add(ValueField(
                    "user_requested_thinking", textValue(thinkingLevelName(level))
                ))
                case None => ()
            }
            fields.add(ValueField(
                "thinking_requested",
                textValue(thinkingLevelName(value.thinking.requested))
            ))
            fields.add(ValueField(
                "thinking_effective",
                textValue(thinkingLevelName(value.thinking.effective))
            ))
            fields.add(ValueField(
                "thinking_mode",
                textValue(thinkingControlModeName(value.thinking.mode))
            ))
            match (value.thinking.budgetTokens) {
                case Some(tokens) => fields.add(ValueField(
                    "thinking_budget_tokens", integerValue(tokens)
                ))
                case None => ()
            }
            fields.add(ValueField(
                "thinking_constraints",
                resolutionConstraintsValue(value.thinking.constraints)
            ))
            fields.add(ValueField(
                "output_requested_hard_limit",
                integerValue(value.output.requestedHardLimit)
            ))
            fields.add(ValueField(
                "output_effective_wire_limit",
                integerValue(value.output.effectiveWireLimit)
            ))
            fields.add(ValueField(
                "output_constraints",
                resolutionConstraintsValue(value.output.constraints)
            ))
        case None => ()
    }
    objectValue(fields.toArray())
}

func modelRequestCheckpointValue(request: ModelRequest): AgentValue {
    modelRequestSnapshotValue(request)
}

func modelRequestFromCheckpoint(value: AgentValue, requestId: String): Result<ModelRequest> {
    modelRequestFromSnapshotValue(value, requestId)
}

func modelBlockKindName(value: ModelBlockKind): String {
    match (value) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Reasoning => "reasoning"
        case ModelBlockKind.ToolCall => "tool_call"
        case ModelBlockKind.ToolResult => "tool_result"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func modelBlockKindFromName(value: String): ModelBlockKind {
    match (value) {
        case "text" => ModelBlockKind.Text
        case "image" => ModelBlockKind.Image
        case "reasoning" => ModelBlockKind.Reasoning
        case "tool_call" => ModelBlockKind.ToolCall
        case "tool_result" => ModelBlockKind.ToolResult
        case "refusal" => ModelBlockKind.Refusal
        case "error" => ModelBlockKind.Error
        case "unknown" => ModelBlockKind.Unknown
        case _ => throw IllegalArgumentException("unknown durable model block kind")
    }
}

func thinkingLevelFromName(value: String): ThinkingLevel {
    match (value) {
        case "off" => ThinkingLevel.Off
        case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low
        case "medium" => ThinkingLevel.Medium
        case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh
        case "max" => ThinkingLevel.Max
        case _ => throw IllegalArgumentException("unknown durable thinking level")
    }
}

func thinkingControlModeFromName(value: String): ThinkingControlMode {
    match (value) {
        case "none" => ThinkingControlMode.NoThinking
        case "toggle" => ThinkingControlMode.Toggle
        case "effort" => ThinkingControlMode.Effort
        case "budget" => ThinkingControlMode.Budget
        case "adaptive" => ThinkingControlMode.Adaptive
        case _ => throw IllegalArgumentException("unknown durable thinking mode")
    }
}

func thinkingPreferenceSourceFromName(value: String): ThinkingPreferenceSource {
    match (value) {
        case "explicit_user" => ThinkingPreferenceSource.ExplicitUser
        case "mode_preference" => ThinkingPreferenceSource.ModePreference
        case "model_default" => ThinkingPreferenceSource.ModelDefault
        case _ => throw IllegalArgumentException("unknown durable thinking source")
    }
}

func modelToolChoiceFromName(value: String): ModelToolChoice {
    match (value) {
        case "auto" => ModelToolChoice.Auto
        case "none" => ModelToolChoice.NoTools
        case "required" => ModelToolChoice.Required
        case _ => throw IllegalArgumentException("unknown durable tool choice")
    }
}

func modelAttemptReplayBarrierNameForCore(value: ModelAttemptReplayBarrier): String {
    match (value) {
        case ModelAttemptReplayBarrier.NoBarrier => "none"
        case ModelAttemptReplayBarrier.ToolEvidence => "tool_evidence"
        case ModelAttemptReplayBarrier.ProviderTerminal => "provider_terminal"
        case ModelAttemptReplayBarrier.Cancelled => "cancelled"
        case ModelAttemptReplayBarrier.RunDeadline => "run_deadline"
    }
}

func thinkingPreferenceSourceName(value: ThinkingPreferenceSource): String {
    match (value) {
        case ThinkingPreferenceSource.ExplicitUser => "explicit_user"
        case ThinkingPreferenceSource.ModePreference => "mode_preference"
        case ThinkingPreferenceSource.ModelDefault => "model_default"
    }
}

func resolutionConstraintsValue(values: Array<ResolutionConstraint>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(objectValue([
            ValueField("target", textValue(resolutionConstraintTargetName(value.target))),
            ValueField("kind", textValue(resolutionConstraintKindName(value.kind))),
            ValueField("before", resolutionValueValue(value.before)),
            ValueField("after", resolutionValueValue(value.after))
        ]))
    }
    listValue(result.toArray())
}

func resolutionConstraintsFromValue(value: AgentValue): Array<ResolutionConstraint> {
    let result = ArrayList<ResolutionConstraint>()
    if (value.unifiedKind != ValueKind.List) {
        throw IllegalArgumentException("durable resolution constraints must be a list")
    }
    for (raw in value.items) {
        let target = match (requiredCoreTextField(raw, "target")) {
            case "output_limit" => ResolutionConstraintTarget.OutputLimit
            case "thinking_level" => ResolutionConstraintTarget.ThinkingLevel
            case _ => throw IllegalArgumentException("unknown durable resolution constraint target")
        }
        let kind = match (requiredCoreTextField(raw, "kind")) {
            case "model_output_limit" => ResolutionConstraintKind.ModelOutputLimit
            case "endpoint_output_limit" => ResolutionConstraintKind.EndpointOutputLimit
            case "model_supported_level" => ResolutionConstraintKind.ModelSupportedLevel
            case "attempt_recovery_ceiling" => ResolutionConstraintKind.AttemptRecoveryCeiling
            case "available_thinking_budget" => ResolutionConstraintKind.AvailableThinkingBudget
            case _ => throw IllegalArgumentException("unknown durable resolution constraint kind")
        }
        let before = resolutionValueFromValue(
            requiredCoreValueField(raw, "before"), target
        )
        let after = resolutionValueFromValue(
            requiredCoreValueField(raw, "after"), target
        )
        result.add(ResolutionConstraint(target, kind, before, after))
    }
    result.toArray()
}

func resolutionValueFromValue(
    value: AgentValue,
    target: ResolutionConstraintTarget
): ResolutionValue {
    match (target) {
        case ResolutionConstraintTarget.OutputLimit =>
            if (value.unifiedKind != ValueKind.Number) {
                throw IllegalArgumentException("durable output constraint value must be an integer")
            }
            ResolutionValue.TokenLimit(Int64.parse(value.asNumberText()))
        case ResolutionConstraintTarget.ThinkingLevel =>
            if (value.unifiedKind != ValueKind.Text) {
                throw IllegalArgumentException("durable thinking constraint value must be text")
            }
            ResolutionValue.ThinkingValue(thinkingLevelFromName(value.text))
    }
}

func resolutionValueValue(value: ResolutionValue): AgentValue {
    match (value) {
        case ResolutionValue.TokenLimit(tokens) => integerValue(tokens)
        case ResolutionValue.ThinkingValue(level) => textValue(thinkingLevelName(level))
    }
}

func resolutionConstraintTargetName(value: ResolutionConstraintTarget): String {
    match (value) {
        case ResolutionConstraintTarget.OutputLimit => "output_limit"
        case ResolutionConstraintTarget.ThinkingLevel => "thinking_level"
    }
}

func resolutionConstraintKindName(value: ResolutionConstraintKind): String {
    match (value) {
        case ResolutionConstraintKind.ModelOutputLimit => "model_output_limit"
        case ResolutionConstraintKind.EndpointOutputLimit => "endpoint_output_limit"
        case ResolutionConstraintKind.ModelSupportedLevel => "model_supported_level"
        case ResolutionConstraintKind.AttemptRecoveryCeiling => "attempt_recovery_ceiling"
        case ResolutionConstraintKind.AvailableThinkingBudget => "available_thinking_budget"
    }
}

func thinkingControlModeName(value: ThinkingControlMode): String {
    match (value) {
        case ThinkingControlMode.NoThinking => "none"
        case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"
        case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive"
    }
}

func attemptPolicyReasonName(value: AttemptPolicyReason): String {
    match (value) {
        case AttemptPolicyReason.Initial => "initial"
        case AttemptPolicyReason.Retry => "retry"
        case AttemptPolicyReason.DeadlineEscalation => "deadline_escalation"
        case AttemptPolicyReason.OutputLimitRecovery => "output_limit_recovery"
    }
}

func attemptFailureKindName(value: AttemptFailureKind): String {
    match (value) {
        case AttemptFailureKind.ConnectTimeout => "connect_timeout"
        case AttemptFailureKind.FirstResponseTimeout => "first_response_timeout"
        case AttemptFailureKind.StreamIdleTimeout => "stream_idle_timeout"
        case AttemptFailureKind.AttemptSoftDeadlineExceeded => "attempt_soft_deadline_exceeded"
        case AttemptFailureKind.AttemptHardDeadlineExceeded => "attempt_hard_deadline_exceeded"
        case AttemptFailureKind.DecisionIncompleteAtDeadline => "decision_incomplete_at_deadline"
        case AttemptFailureKind.ProviderTerminalMissing => "provider_terminal_missing"
        case AttemptFailureKind.ProtocolIncomplete => "protocol_incomplete"
        case AttemptFailureKind.OutputLimited => "output_limited"
        case AttemptFailureKind.OutputLimitedBeforeDecision => "output_limited_before_decision"
        case AttemptFailureKind.ProviderTransportError => "provider_transport_error"
        case AttemptFailureKind.ProviderProtocolError => "provider_protocol_error"
        case AttemptFailureKind.MalformedToolArguments => "malformed_tool_arguments"
        case AttemptFailureKind.UserCancelled => "user_cancelled"
        case AttemptFailureKind.RunDeadlineExceeded => "run_deadline_exceeded"
    }
}

func recoveredDurableModelResult(decision: ModelDecision): DurableModelResult {
    let blocks = ArrayList<ModelBlock>()
    for (value in decision.blocks) { blocks.add(value.block) }
    DurableModelResult(
        ModelReply(
            blocks.toArray(),
            acceptedOutput: true,
            providerId: decision.providerId,
            responseId: decision.providerResponseId,
            terminalEvidence: Some(decision.terminalEvidence),
            completionDisposition: decision.completionDisposition,
            decisionOutcome: decision.outcome,
            validationVersion: decision.validatorVersion
        ),
        decision,
        recovered: true
    )
}

func thinkingLevelName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func modelToolChoiceName(value: ModelToolChoice): String {
    match (value) {
        case ModelToolChoice.Auto => "auto"
        case ModelToolChoice.NoTools => "none"
        case ModelToolChoice.Required => "required"
    }
}

func validatedModelDecision(
    semanticRequestId: SemanticModelRequestId,
    attemptId: ModelAttemptId,
    reply: ModelReply
): Result<ModelDecision> {
    let evidence = match (reply.terminalEvidence) {
        case Some(value) => value
        case None => return invalidAttemptDecision(
            AttemptFailureKind.ProviderTerminalMissing,
            "model.decision_terminal_missing",
            "provider reply has no terminal evidence"
        )
    }
    if (!evidence.messageTerminalObserved) {
        return invalidAttemptDecision(
            AttemptFailureKind.ProviderTerminalMissing,
            "model.decision_terminal_unconfirmed",
            "provider did not confirm a message terminal boundary"
        )
    }
    match (reply.completionDisposition) {
        case CompletionDisposition.Complete | CompletionDisposition.ToolUse => ()
        case CompletionDisposition.OutputLimited => return invalidAttemptDecision(
            AttemptFailureKind.OutputLimitedBeforeDecision,
            "model.output_limited_before_decision",
            "provider exhausted the output budget before an accepted decision boundary",
            fields: [
                ErrorField("provider_profile_id", reply.providerId),
                ErrorField("provider_response_id", reply.responseId),
                ErrorField("attempt_id", attemptId.value),
                ErrorField("api_protocol", evidence.protocol),
                ErrorField("raw_stop_reason", evidence.rawStopReason),
                ErrorField("completion_tokens", reply.outputTokens.toString()),
                ErrorField("reasoning_tokens", reply.reasoningTokens.toString()),
                ErrorField("decision_output_tokens", max(0,
                    reply.outputTokens - reply.reasoningTokens).toString()),
                ErrorField("reasoning_share", if (reply.outputTokens > 0) {
                    (Float64(reply.reasoningTokens) / Float64(reply.outputTokens)).toString()
                } else { "" }),
                ErrorField("partial_stream", "true"),
                ErrorField("decision_boundary_observed", "false"),
                ErrorField("decision_boundary_accepted", "false")
            ]
        )
        case CompletionDisposition.ProtocolIncomplete | CompletionDisposition.Unknown =>
            return invalidAttemptDecision(
                AttemptFailureKind.ProtocolIncomplete,
                "model.decision_completion_rejected",
                "provider terminal disposition is incomplete"
            )
        case _ => return invalidAttemptDecision(
            AttemptFailureKind.ProviderProtocolError,
            "model.decision_completion_rejected",
            "provider terminal disposition is not executable"
        )
    }
    if (!reply.acceptedOutput || reply.validationVersion < 1) {
        return invalidDecision("model.decision_validation_rejected",
            "provider reply did not pass adapter validation")
    }
    for (block in reply.blocks) {
        match (block.opaqueState) {
            case Some(state) => if (state.replayRequired &&
                (state.providerId.trimAscii() == "" || state.protocol.trimAscii() == "" ||
                    state.payload == "")) {
                return invalidDecision(
                    "model.decision_replay_state_incomplete",
                    "replay-required provider state is incomplete"
                )
            }
            case None => ()
        }
    }
    let decisionId = ModelDecisionId(attemptId.value + "-decision")
    let blocks = durableDecisionBlocks(decisionId, reply.blocks)
    if (blocks.isEmpty()) {
        return invalidDecision("model.decision_empty", "validated model decision has no content")
    }
    let semantic = decisionSemanticFrame(blocks)
    let replay = semantic + decisionReplayFrame(blocks) + decisionTerminalFrame(evidence)
    Result.Ok(ModelDecision(
        decisionId, attemptId, semanticRequestId, blocks, evidence,
        DecisionValidationStatus.Validated, reply.completionDisposition,
        reply.decisionOutcome, stableDecisionFingerprint(semantic),
        stableDecisionFingerprint(replay), reply.validationVersion,
        providerId: reply.providerId, providerResponseId: reply.responseId,
        createdAtMillis: agentUtcMillis()
    ))
}

func durableDecisionBlocks(
    decisionId: ModelDecisionId,
    providerBlocks: Array<ModelBlock>
): Array<DurableDecisionBlock> {
    let normalized = ArrayList<ModelBlock>()
    for (block in providerBlocks) {
        if (block.kind == ModelBlockKind.ToolResult) { continue }
        if (block.kind == ModelBlockKind.ToolCall && block.opaqueState.isSome()) {
            normalized.add(ModelBlock(
                ModelBlockKind.Unknown, opaqueState: block.opaqueState
            ))
        }
        if (decisionBlockHasCanonicalContent(block)) {
            normalized.add(copyDecisionBlockWithoutOpaque(block))
        }
        if (block.kind != ModelBlockKind.ToolCall &&
            block.kind != ModelBlockKind.Unknown && block.opaqueState.isSome()) {
            normalized.add(ModelBlock(
                ModelBlockKind.Unknown, opaqueState: block.opaqueState
            ))
        }
    }
    let output = ArrayList<DurableDecisionBlock>()
    for (index in 0..normalized.size) {
        let block = normalized[index]
        output.add(DurableDecisionBlock(
            DecisionBlockId(decisionId.value + "-block-" + index.toString()),
            index,
            block,
            scopedToolCallId: if (block.kind == ModelBlockKind.ToolCall) {
                Some(ScopedToolCallId(
                    decisionId.value + "-tool-" + index.toString()
                ))
            } else { None }
        ))
    }
    output.toArray()
}

func decisionBlockHasCanonicalContent(block: ModelBlock): Bool {
    match (block.kind) {
        case ModelBlockKind.Text | ModelBlockKind.Reasoning |
             ModelBlockKind.Refusal | ModelBlockKind.Error => block.text != ""
        case ModelBlockKind.Unknown => block.opaqueState.isSome() || block.text != ""
        case ModelBlockKind.ToolResult => false
        case _ => true
    }
}

func copyDecisionBlockWithoutOpaque(block: ModelBlock): ModelBlock {
    ModelBlock(
        block.kind, text: block.text, callId: block.callId, name: block.name,
        arguments: block.arguments, isError: block.isError, image: block.image,
        receiptId: block.receiptId,
        opaqueState: if (block.kind == ModelBlockKind.Unknown) {
            block.opaqueState
        } else { None }
    )
}

func decisionSemanticFrame(blocks: Array<DurableDecisionBlock>): String {
    var output = "decision-semantic-v1"
    var semanticOrdinal: Int64 = 0
    for (entry in blocks) {
        let block = entry.block
        if (block.kind == ModelBlockKind.Unknown && block.text == "" &&
            block.opaqueState.isSome()) { continue }
        output += decisionFrame(semanticOrdinal.toString()) +
            decisionFrame(modelBlockFingerprintKind(block.kind)) +
            decisionFrame(block.text) + decisionFrame(block.callId) +
            decisionFrame(block.name) + decisionFrame(canonicalAgentValue(block.arguments)) +
            decisionFrame(block.isError.toString()) + decisionFrame(block.receiptId)
        match (block.image) {
            case Some(image) => output += decisionFrame(image.data) +
                decisionFrame(image.mediaType)
            case None => output += decisionFrame("")
        }
        semanticOrdinal += 1
    }
    output
}

func decisionTerminalFrame(value: TerminalEvidence): String {
    var output = "decision-replay-v1" + decisionFrame(value.protocol) +
        decisionFrame(value.terminalEventKind) + decisionFrame(value.rawStopReason) +
        decisionFrame(value.messageTerminalObserved.toString()) +
        decisionFrame(value.streamEofObserved.toString()) +
        decisionFrame(value.adapterVersion)
    output
}

func decisionReplayFrame(blocks: Array<DurableDecisionBlock>): String {
    var output = "decision-opaque-v1"
    for (entry in blocks) {
        match (entry.block.opaqueState) {
            case Some(state) => output += decisionFrame(entry.ordinal.toString()) +
                decisionFrame(state.providerId) + decisionFrame(state.protocol) +
                decisionFrame(state.itemId) + decisionFrame(state.payload) +
                decisionFrame(state.replayRequired.toString())
            case None => ()
        }
    }
    output
}

func decisionFrame(value: String): String { value.size.toString() + ":" + value }


func stableDecisionFingerprint(value: String): String {
    var hash: UInt64 = 1469598103934665603
    for (byte in unsafe { value.rawData() }) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    "fnv1a64-v1:" + hash.toString()
}

func modelBlockFingerprintKind(kind: ModelBlockKind): String {
    match (kind) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Reasoning => "reasoning"
        case ModelBlockKind.ToolCall => "tool_call"
        case ModelBlockKind.ToolResult => "tool_result"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func invalidDecision<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Protocol, code, message))
}

func invalidAttemptDecision<T>(
    kind: AttemptFailureKind,
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Protocol,
        code,
        message,
        retryable: kind == AttemptFailureKind.OutputLimited ||
            kind == AttemptFailureKind.OutputLimitedBeforeDecision ||
            kind == AttemptFailureKind.ProviderTerminalMissing ||
            kind == AttemptFailureKind.ProtocolIncomplete ||
            kind == AttemptFailureKind.MalformedToolArguments,
        fields: fields,
        attemptFailure: Some(AttemptFailure(kind))
    ))
}

func isAwaitingApproval(status: RunState): Bool {
    match (status) {
        case RunState.WaitingApproval => true
        case _ => false
    }
}

func commitCanonicalModelDecision(
    control: CoreRunControl,
    decisionRuntime: ModelDecisionRuntimePort,
    decision: ModelDecision
): Result<Array<CommittedToolCallRef>> {
    if (decision.validationStatus != DecisionValidationStatus.Validated ||
        !decision.terminalEvidence.messageTerminalObserved) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "thread.decision_not_validated",
            "canonical projection requires a validated durable Model Decision"
        ))
    }
    let active = match (control.runtime.activeRunControl159()) {
        case Some(value) => value
        case None => return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "thread.model_result_without_owner",
            "model result has no active canonical Run"
        ))
    }
    let snapshot = control.runtime.threadSnapshot()
    let drafts = ArrayList<ThreadItemDraft>()
    let toolSources = ArrayList<CommittedToolCallSource>()
    for (entry in decision.blocks) {
        let block = entry.block
        let content: ?ThreadItemContent = match (block.kind) {
            case ModelBlockKind.Text => Some(ThreadItemContent.AssistantMessage([
                    ThreadMessagePart.Text(block.text)
                ]))
            case ModelBlockKind.Refusal | ModelBlockKind.Error =>
                Some(ThreadItemContent.AssistantMessage([
                    ThreadMessagePart.Refusal(block.text)
                ]))
            case ModelBlockKind.Image =>
                let image = block.image.getOrThrow()
                Some(ThreadItemContent.AssistantMessage([
                    ThreadMessagePart.Image(ThreadImage(
                        match (image.sourceKind) {
                            case ModelImageSourceKind.Url => ThreadImageSourceKind.Url
                            case ModelImageSourceKind.Base64 => ThreadImageSourceKind.Base64
                        },
                        image.data,
                        mediaType: image.mediaType
                    ))
                ]))
            case ModelBlockKind.Reasoning => Some(ThreadItemContent.ReasoningReference(
                    "reasoning-" + entry.id.value,
                    block.text
                ))
            case ModelBlockKind.Unknown => match (block.opaqueState) {
                case Some(value) => Some(ThreadItemContent.ProviderOpaqueItem(value))
                case None => if (block.text == "") { None } else {
                    Some(ThreadItemContent.SystemNote(block.text))
                }
            }
            case ModelBlockKind.ToolCall => Some(ThreadItemContent.ToolCall(
                CanonicalToolCallId(block.callId),
                block.name,
                block.arguments
            ))
            case ModelBlockKind.ToolResult => return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "thread.model_batch_tool_boundary",
                    "tool protocol must commit through the Operation Runtime"
                )
            )
        }
        match (content) {
            case Some(value) =>
                let itemId = ItemId("decision-item-" + entry.id.value)
                drafts.add(ThreadItemDraft(
                    itemId,
                    value,
                    ItemProvenance(
                        if (block.kind == ModelBlockKind.Unknown) {
                            if (entry.ordinal + 1 < decision.blocks.size &&
                                decision.blocks[entry.ordinal + 1].block.kind ==
                                    ModelBlockKind.ToolCall) {
                                "provider_tool_call"
                            } else { "provider" }
                        } else { "model" },
                        runId: Some(control.runId)
                    ),
                    createdAtMillis: agentUtcMillis(),
                    sourceDecisionId: Some(decision.id),
                    sourceDecisionBlockId: Some(entry.id)
                ))
                match (entry.scopedToolCallId) {
                    case Some(scopedId) => toolSources.add(CommittedToolCallSource(
                        decision.id, scopedId, itemId, block
                    ))
                    case None => ()
                }
            case None => ()
        }
    }
    var alreadyCommitted: Int64 = 0
    for (draft in drafts) {
        for (item in snapshot.items where item.id.value == draft.id.value) {
            alreadyCommitted += 1
        }
    }
    if (alreadyCommitted == drafts.size) {
        let sources = toolSources.toArray()
        match (decisionRuntime.recordCanonicalProjection(decision.id, sources)) {
            case Result.Ok(_) => return control.runtime.attestCommittedToolCalls(sources)
            case Result.Err(error) => return Result.Err(error)
        }
    }
    if (alreadyCommitted != 0) {
        return Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "thread.partial_decision_projection",
            "canonical Thread contains only part of one durable Model Decision"
        ))
    }
    match (control.runtime.commitBatch(ResultBatchEnvelope(
        snapshot.thread.id,
        active[1],
        active[2],
        active[3],
        snapshot.nextResultSequence,
        drafts.toArray()
    ))) {
        case SemanticBatchCommitDecision.Committed(_, _) =>
            let sources = toolSources.toArray()
            match (decisionRuntime.recordCanonicalProjection(decision.id, sources)) {
                case Result.Ok(_) => control.runtime.attestCommittedToolCalls(sources)
                case Result.Err(error) => Result.Err(error)
            }
        case SemanticBatchCommitDecision.Stale(reason) => Result.Err(AgentError(
            AgentErrorKind.Conflict,
            reason.code,
            reason.message
        ))
        case SemanticBatchCommitDecision.Rejected(error) => Result.Err(error)
    }
}

// Provider messages are disposable DTOs. This is the only normal AgentCore
// projection from immutable Thread Items into the provider-neutral protocol.
public func modelMessagesFromProjection(projection: ModelContextProjection): Array<ModelMessage> {
    modelMessagesFromProjectionWithContinuation(projection, [])
}

// Only Core supplies records read from the exact consumed canonical claim.
// The public generic projection continues to ignore every SystemNote.
func modelMessagesFromProjectionWithContinuation(projection: ModelContextProjection,
    continuationInputs: Array<(ItemId, ModelMessage)>): Array<ModelMessage> {
    let messages = ArrayList<ModelMessage>()
    let toolCallOpaque = ArrayList<OpaqueProviderState>()
    var nextToolCallOpaque: Int64 = 0
    match (projection.checkpoint) {
        case Some(checkpoint) =>
            messages.add(ModelMessage(
                ModelRole.User,
                [ModelBlock(
                    ModelBlockKind.Text,
                    text: checkpointProjectionText(checkpoint)
                )]
            ))
        case None => ()
    }
    let internalReadCalls = HashSet<String>()
    for (item in projection.recentItems where isContextReadItem(item)) {
        match (item.content) { case ThreadItemContent.ToolCall(id, _, _) => internalReadCalls.add(item.turnId.value + "\u{0000}" + id.value); case _ => () }
    }
    for (item in projection.recentItems) {
        match (item.content) {
            case ThreadItemContent.ToolCall(id, _, _) => if (internalReadCalls.contains(item.turnId.value + "\u{0000}" + id.value)) { continue }
            case ThreadItemContent.ToolResult(id, _, _, _, _) => if (internalReadCalls.contains(item.turnId.value + "\u{0000}" + id.value)) { continue }
            case _ => ()
        }
        match (item.content) {
            case ThreadItemContent.UserMessage(parts) =>
                messages.add(ModelMessage(ModelRole.User, projectedMessageParts(parts)))
            case ThreadItemContent.AssistantMessage(parts) =>
                appendProjectedAssistant(messages, projectedMessageParts(parts))
            case ThreadItemContent.ToolCall(callId, name, arguments) =>
                let opaque: ?OpaqueProviderState = if (nextToolCallOpaque < toolCallOpaque.size) {
                    let value = Some(toolCallOpaque[nextToolCallOpaque])
                    nextToolCallOpaque += 1
                    value
                } else {
                    None
                }
                appendProjectedAssistant(messages, [ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: callId.value,
                    name: name,
                    arguments: arguments,
                    opaqueState: opaque
                )])
            case ThreadItemContent.ToolResult(callId, _, receiptId, result, isError) =>
                appendProjectedToolResult(messages, ModelBlock(
                    ModelBlockKind.ToolResult,
                    callId: callId.value,
                    name: projectedToolName(projection.recentItems, callId.value),
                    arguments: result,
                    isError: isError,
                    receiptId: receiptId
                ))
            case ThreadItemContent.ReasoningReference(_, summary) =>
                appendProjectedAssistant(messages, [ModelBlock(
                    ModelBlockKind.Reasoning, text: summary
                )])
            case ThreadItemContent.ProviderOpaqueItem(state) =>
                if (item.provenance.source == "provider_tool_call") {
                    toolCallOpaque.add(state)
                } else {
                    appendProjectedAssistant(messages, [ModelBlock(
                        ModelBlockKind.Unknown, opaqueState: Some(state)
                    )])
                }
            case ThreadItemContent.ArtifactReference(hash, mime, size) =>
                appendProjectedAssistant(messages, [ModelBlock(
                    ModelBlockKind.Text,
                    text: "[artifact " + hash + " " + mime + " " + size.toString() + "]"
                )])
            // System notes are durable audit/user-visible facts, not model
            // instructions. Never silently promote one into the prompt.
            case ThreadItemContent.SystemNote(_) =>
                if (isContinuationInitiatorDescription(item) || isContinuationHistoryDescription(item)) {
                    for ((id, message) in continuationInputs where id.value == item.id.value) { messages.add(message) }
                }
        }
    }
    while (nextToolCallOpaque < toolCallOpaque.size) {
        appendProjectedAssistant(messages, [ModelBlock(
            ModelBlockKind.Unknown,
            opaqueState: Some(toolCallOpaque[nextToolCallOpaque])
        )])
        nextToolCallOpaque += 1
    }
    messages.toArray()
}

public func modelMessagesFromCanonicalItems(items: Array<ThreadItem>): Array<ModelMessage> {
    modelMessagesFromProjection(ModelContextProjection(
        0, None, items, objectValue([]), 0, false
    ))
}

func projectedMessageParts(parts: Array<ThreadMessagePart>): Array<ModelBlock> {
    let blocks = ArrayList<ModelBlock>()
    for (part in parts) {
        match (part) {
            case ThreadMessagePart.Text(value) =>
                blocks.add(ModelBlock(ModelBlockKind.Text, text: value))
            case ThreadMessagePart.Refusal(value) =>
                blocks.add(ModelBlock(ModelBlockKind.Refusal, text: value))
            case ThreadMessagePart.Image(image) =>
                match (image.sourceKind) {
                    case ThreadImageSourceKind.Url | ThreadImageSourceKind.Base64 =>
                        blocks.add(ModelBlock(
                            ModelBlockKind.Image,
                            image: Some(ModelImage(
                                if (image.sourceKind == ThreadImageSourceKind.Url) {
                                    ModelImageSourceKind.Url
                                } else {
                                    ModelImageSourceKind.Base64
                                },
                                image.data,
                                mediaType: image.mediaType
                            ))
                        ))
                    case ThreadImageSourceKind.Artifact =>
                        blocks.add(ModelBlock(
                            ModelBlockKind.Text,
                            text: "[image artifact " + image.data + "]"
                        ))
                }
        }
    }
    blocks.toArray()
}

func appendProjectedAssistant(
    messages: ArrayList<ModelMessage>,
    blocks: Array<ModelBlock>
): Unit {
    if (!messages.isEmpty() && messages[messages.size - 1].role == ModelRole.Assistant) {
        let merged = ArrayList<ModelBlock>()
        merged.add(all: messages[messages.size - 1].blocks)
        merged.add(all: blocks)
        messages[messages.size - 1] = ModelMessage(ModelRole.Assistant, merged.toArray())
    } else {
        messages.add(ModelMessage(ModelRole.Assistant, blocks))
    }
}

func appendProjectedToolResult(
    messages: ArrayList<ModelMessage>,
    block: ModelBlock
): Unit {
    if (!messages.isEmpty() && isToolResultMessage(messages[messages.size - 1])) {
        let merged = ArrayList<ModelBlock>()
        merged.add(all: messages[messages.size - 1].blocks)
        merged.add(block)
        messages[messages.size - 1] = ModelMessage(ModelRole.User, merged.toArray())
    } else {
        messages.add(ModelMessage(ModelRole.User, [block]))
    }
}

func isToolResultMessage(message: ModelMessage): Bool {
    if (message.role != ModelRole.User || message.blocks.isEmpty()) {
        return false
    }
    for (block in message.blocks where block.kind != ModelBlockKind.ToolResult) {
        return false
    }
    true
}

func projectedToolName(items: Array<ThreadItem>, callId: String): String {
    for (item in items) {
        match (item.content) {
            case ThreadItemContent.ToolCall(id, name, _) =>
                if (id.value == callId) { return name }
            case _ => ()
        }
    }
    "tool"
}

func checkpointProjectionText(checkpoint: ContextCheckpoint): String {
    var text = "[Compacted canonical Thread through Item " +
        checkpoint.coversThroughItemOrdinal.toString() + "]"
    match (checkpoint.structuredSummary.field("deterministic_summary")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Text && value.text != "") {
            text += "\n" + value.text
        }
        case None => match (checkpoint.structuredSummary.field("summary")) {
            case Some(value) => if (value.unifiedKind == ValueKind.Text && value.text != "") {
                text += "\n" + value.text
            }
            case None => ()
        }
    }
    if (checkpoint.activeGoal != "") { text += "\nActive goal: " + checkpoint.activeGoal }
    for (note in checkpoint.durableNotes) { text += "\nDurable note: " + note }
    for (reference in checkpoint.artifactReferences) {
        text += "\nArtifact: " + reference
    }
    text
}

func coreWorkspaceId(request: AgentRunRequest): String {
    let root = request.toolContext.workspaceRoot.trimAscii()
    if (root == "") { "workspace:default" } else { root }
}

func coreUserContent(message: ModelMessage): ThreadItemContent {
    let parts = ArrayList<ThreadMessagePart>()
    for (block in message.blocks) {
        match (block.kind) {
            case ModelBlockKind.Text => if (block.text != "") {
                parts.add(ThreadMessagePart.Text(block.text))
            }
            case ModelBlockKind.Image =>
                let image = block.image.getOrThrow()
                parts.add(ThreadMessagePart.Image(ThreadImage(
                    match (image.sourceKind) {
                        case ModelImageSourceKind.Url => ThreadImageSourceKind.Url
                        case ModelImageSourceKind.Base64 => ThreadImageSourceKind.Base64
                    },
                    image.data,
                    mediaType: image.mediaType
                )))
            case _ => ()
        }
    }
    if (parts.isEmpty()) {
        parts.add(ThreadMessagePart.Text("[empty user message]"))
    }
    ThreadItemContent.UserMessage(parts.toArray())
}

func coreModelLane(request: AgentRunRequest, catalog: ToolCatalog): ModelLane {
    let shared = catalog.sharedToolSetSnapshot159("catalog-" + request.runId.value,
        request.capabilities, threadId: Some(ThreadId(request.sessionId.value)))
    match (shared) {
        // No Registry-owned data exists in this historical fixture catalog.
        case None => coreLegacyModelLane159(request, catalog)
        case Some(value) =>
            // The lane obtains its own prepaid handle before construction.
            // Closing this temporary share cannot retire the lane's data.
            try { coreSharedModelLaneFrame159(request, value) }
            finally { value.close159() }
    }
}
func coreSharedModelLaneFrame159(request: AgentRunRequest, toolSet: SharedToolSetSnapshot159): ModelLane {
    modelLaneWithSharedToolSet159(ModelLaneRole.Main, "configured", request.model, "agent-core",
        ModelLaneCapabilitiesSnapshot(streaming: true, tools: toolSet.hasAvailableTools159(),
            reasoning: request.thinking != ThinkingLevel.Off,
            structuredOutput: request.structuredOutput.isSome(), imageInput: !request.imageInputs.isEmpty(),
            promptCache: request.cachePolicy == ModelCachePolicy.StablePrefix, providerOpaqueState: true),
        request.contextWindow, request.budget.maxOutputTokens, request.providerSafetyMargin,
        "conservative-v1", if (request.autoRetry) { "bounded-retry-v1" } else { "never" },
        if (request.cachePolicy == ModelCachePolicy.StablePrefix) { "stable-prefix" } else { "default" },
        toolSet, "system-v1")
}

func coreLegacyModelLane159(request: AgentRunRequest, catalog: ToolCatalog): ModelLane {
    let toolSet = catalog.toolSetSnapshot(
        "catalog-" + request.runId.value,
        request.capabilities, threadId: Some(ThreadId(request.sessionId.value))
    )
    ModelLane(
        ModelLaneRole.Main,
        "configured",
        request.model,
        "agent-core",
        ModelLaneCapabilitiesSnapshot(
            streaming: true,
            tools: coreModelToolSetHasAvailableTool(toolSet),
            reasoning: request.thinking != ThinkingLevel.Off,
            structuredOutput: request.structuredOutput.isSome(),
            imageInput: !request.imageInputs.isEmpty(),
            promptCache: request.cachePolicy == ModelCachePolicy.StablePrefix,
            providerOpaqueState: true
        ),
        request.contextWindow,
        request.budget.maxOutputTokens,
        request.providerSafetyMargin,
        "conservative-v1",
        if (request.autoRetry) { "bounded-retry-v1" } else { "never" },
        if (request.cachePolicy == ModelCachePolicy.StablePrefix) {
            "stable-prefix"
        } else {
            "default"
        },
        toolSet,
        "system-v1"
    )
}

func coreModelToolSetHasAvailableTool(snapshot: ToolSetSnapshot): Bool {
    for (entry in snapshot.entries where entry.availableAtSnapshot) {
        return true
    }
    false
}

func coreModelToolDefinitions(snapshot: ToolSetSnapshot): Array<ModelToolDefinition> {
    let definitions = ArrayList<ModelToolDefinition>()
    for (entry in snapshot.entries where entry.availableAtSnapshot) {
        definitions.add(ModelToolDefinition(
            entry.name,
            entry.description,
            entry.inputSchema
        ))
    }
    definitions.toArray()
}

func validateCoreModelLane159(lane: ModelLane, threadId: ThreadId): Result<Unit> {
    if (lane.permitsToolThread159(threadId) && lane.hasCompleteToolIdentities159()) { return Result.Ok(()) }
    validateCoreToolSetSnapshot(lane.toolSet, threadId)
}

func validateCoreToolSetSnapshot(snapshot: ToolSetSnapshot, threadId: ThreadId): Result<Unit> {
    match (snapshot.threadId) {
        case Some(owner) => if (owner.value != threadId.value) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "run.tool_snapshot_thread_mismatch", "durable Run tool snapshot belongs to another Thread"))
        }
        case None => ()
    }
    for (entry in snapshot.entries where !entry.hasCompleteIdentity()) {
        return Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.tool_snapshot_identity_missing",
            "durable Run tool snapshot does not contain a complete implementation identity",
            fields: [ErrorField("tool", entry.name)]
        ))
    }
    Result.Ok(())
}

func coreCatalogMatchesLane159(catalog: ToolCatalog, lane: ModelLane,
    capabilities: CapabilitySet, thread: ThreadId): Bool {
    let shared = lane.forkOwnedToolSetSnapshot159()
    try { coreCatalogMatchesLaneFrame159(catalog, lane, shared, capabilities, thread) }
    finally { match (shared) { case Some(value) => value.close159(); case None => () } }
}
private func coreCatalogMatchesLaneFrame159(catalog: ToolCatalog, lane: ModelLane,
    shared: ?SharedToolSetSnapshot159, capabilities: CapabilitySet, thread: ThreadId): Bool {
    match (shared) {
        case Some(value) => catalog.sharedToolSetSnapshotMatches159(value, "catalog-observed", capabilities, threadId: Some(thread))
        case None => catalog.toolSetSnapshotMatches159(lane.legacyToolSetSnapshot159().getOrThrow(),
            "catalog-observed", capabilities, threadId: Some(thread))
    }
}

func coreModelToolsForRequest159(runtime: AgentThreadRuntime, thread: ThreadId): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let view = runtime.activeRunOwned159()
    try { coreModelToolsFromActiveFrame159(view, thread) }
    finally { match (view) { case Some(value) => value.returnActiveRunFrame159(); case None => () } }
}
private func coreModelToolsFromActiveFrame159(view: ?OwnedActiveRunFrame159, thread: ThreadId): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let active = match (view) { case Some(value) => value.snapshot159()
        case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "run.model_lane_snapshot_missing", "active Run has no immutable ModelLane tool snapshot")) }
    match (validateCoreModelLane159(active.lane, thread)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let owned = active.lane.ownedModelTools159()
    let definitions = match (owned) { case Some(value) => value.definitionsForPreparedRequest159()
        case None => coreModelToolDefinitions(active.lane.toolSet) }
    Result.Ok((owned, definitions))
}

func coreActiveRunToolLane159(runtime: AgentThreadRuntime): Result<ModelLane> {
    let owned = runtime.activeRunOwned159()
    try { coreActiveRunToolLaneFrame159(runtime, owned) }
    finally { match (owned) { case Some(value) => value.returnActiveRunFrame159(); case None => () } }
}
private func coreActiveRunToolLaneFrame159(runtime: AgentThreadRuntime,
    owned: ?OwnedActiveRunFrame159): Result<ModelLane> {
    match (owned) {
        case Some(value) =>
            let active = value.snapshot159()
            match (validateCoreModelLane159(active.lane, coreOwnedControlMetadata(runtime).thread.id)) {
                case Result.Ok(_) => match (active.lane.forkOwnedLaneFrame159()) {
                    case Some(copy) => Result.Ok(copy)
                    case None => Result.Ok(active.lane)
                }
                case Result.Err(error) => Result.Err(error)
            }
        case None => Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.model_lane_snapshot_missing",
            "active Run has no immutable ModelLane tool snapshot"
        ))
    }
}

func coreBudgetSnapshot(budget: ResourceBudget): AgentValue {
    objectValue([
        ValueField("max_turns", integerValue(budget.maxTurns)),
        ValueField("max_drain_turns", integerValue(budget.maxDrainTurns)),
        ValueField("max_model_requests", integerValue(budget.maxModelRequests)),
        ValueField("max_tool_calls", integerValue(budget.maxToolCalls)),
        ValueField("max_concurrent_tools", integerValue(budget.maxConcurrentTools)),
        ValueField("max_total_input_tokens", integerValue(budget.maxTotalInputTokens)),
        ValueField("max_total_output_tokens", integerValue(budget.maxTotalOutputTokens)),
        ValueField("max_cost_micros", integerValue(budget.maxCostMicros)),
        ValueField("deadline_millis", integerValue(budget.deadlineMillis))
    ])
}

func approvalDetail(decision: ApprovalDecision): String {
    match (decision) {
        case ApprovalDecision.Approve => "approval.approved"
        case ApprovalDecision.ApproveSession => "approval.approved_for_session"
        case ApprovalDecision.Reject => "approval.rejected"
        case ApprovalDecision.RejectWithReason(_) => "approval.rejected_with_reason"
    }
}

func approvalRequestEventValue(request: ApprovalRequest): AgentValue {
    objectValue(
        [
            ValueField("code", textValue("approval.requested")),
            ValueField("type", textValue("approval_request")),
            ValueField("request_id", textValue(request.operationId.value)),
            ValueField("session_id", textValue(request.sessionId)),
            ValueField("tool", textValue(request.toolName)),
            ValueField("call_id", textValue(request.callId)),
            ValueField("argument_hash", textValue(request.argumentHash)),
            ValueField("risk_flags", approvalEventStrings(request.riskFlags)),
            ValueField("risk_level", textValue(approvalRiskLevelName(request.metadata.assessment.level))),
            ValueField("risk_reasons", approvalEventStrings(request.metadata.assessment.reasons)),
            ValueField("permission_class", textValue(request.metadata.capabilityLabel)),
            ValueField("decision_source", textValue(approvalDecisionSourceName(request.decisionSource))),
            ValueField("session_approval_allowed", boolValue(request.sessionApprovalAllowed)),
            ValueField("requested_capabilities", listValue([textValue(request.metadata.capabilityLabel)]))
        ]
    )
}

func approvalDecisionEventValue(
    request: ApprovalRequest,
    decision: ApprovalDecision
): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("code", textValue(approvalDetail(decision))))
    fields.add(ValueField("type", textValue("approval_decision")))
    fields.add(ValueField("request_id", textValue(request.operationId.value)))
    fields.add(ValueField("tool", textValue(request.toolName)))
    fields.add(ValueField("argument_hash", textValue(request.argumentHash)))
    fields.add(ValueField("risk_flags", approvalEventStrings(request.riskFlags)))
    fields.add(ValueField("risk_level", textValue(approvalRiskLevelName(request.metadata.assessment.level))))
    fields.add(ValueField("risk_reasons", approvalEventStrings(request.metadata.assessment.reasons)))
    fields.add(ValueField("permission_class", textValue(request.metadata.capabilityLabel)))
    fields.add(ValueField("decision_source", textValue(approvalDecisionSourceName(request.decisionSource))))
    match (request.review) {
        case Some(review) =>
            fields.add(ValueField("decision", textValue(match (review.decision) {
                case ApprovalReviewDecision.Approve => "approve"
                case ApprovalReviewDecision.Deny => "deny"
                case ApprovalReviewDecision.AskUser => "ask_user"
            })))
            fields.add(ValueField("reviewer_risk_level", textValue(review.riskLevel)))
            fields.add(ValueField("reason", textValue(review.reason)))
            fields.add(ValueField("reviewer_model", textValue(review.reviewerModel)))
            fields.add(ValueField("latency_ms", integerValue(review.latencyMillis)))
            fields.add(ValueField("failure_type", textValue(review.failureType)))
        case None => ()
    }
    objectValue(fields.toArray())
}

func approvalEventStrings(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

func modelEventValue(event: ModelEvent): AgentValue {
    let fields = match (event) {
        case ModelEvent.TextDelta(value) => [
            ValueField("code", textValue("model.text_delta")),
            ValueField("text", textValue(value))
        ]
        case ModelEvent.ReasoningDelta(value) => [
            ValueField("code", textValue("model.reasoning_delta")),
            ValueField("text", textValue(value))
        ]
        case ModelEvent.ToolCallStarted(callId, name) => [
            ValueField("code", textValue("model.tool_started")),
            ValueField("call_id", textValue(callId)),
            ValueField("name", textValue(name))
        ]
        case ModelEvent.ToolArgumentsDelta(callId, value) => [
            ValueField("code", textValue("model.tool_arguments")),
            ValueField("call_id", textValue(callId)),
            ValueField("text", textValue(value))
        ]
        case ModelEvent.ToolCallCompleted(callId) => [
            ValueField("code", textValue("model.tool_completed")),
            ValueField("call_id", textValue(callId))
        ]
        case ModelEvent.UsageUpdated(input, output) => [
            ValueField("code", textValue("model.usage")),
            ValueField("input_tokens", integerValue(input)),
            ValueField("output_tokens", integerValue(output))
        ]
        case ModelEvent.ProviderProgress(value) => providerStreamEventValue(value)
        case ModelEvent.Completed => [ValueField("code", textValue("model.completed"))]
    }
    objectValue(fields)
}

func modelEventReplayBarrier(event: ModelEvent): ?ModelAttemptReplayBarrier {
    match (event) {
        case ModelEvent.ToolCallStarted(_, _) |
            ModelEvent.ToolArgumentsDelta(_, _) |
            ModelEvent.ToolCallCompleted(_) =>
            Some(ModelAttemptReplayBarrier.ToolEvidence)
        case ModelEvent.Completed => Some(ModelAttemptReplayBarrier.ProviderTerminal)
        case ModelEvent.ProviderProgress(value) => match (value) {
            case ProviderStreamEvent.MessageTerminalObserved(_) =>
                Some(ModelAttemptReplayBarrier.ProviderTerminal)
            case _ => None
        }
        case _ => None
    }
}

func modelEventImmediateReplayBarrier(event: ModelEvent): ?ModelAttemptReplayBarrier {
    // A provider stream terminal observation must be durable before the
    // callback returns. ModelEvent.Completed remains deferred so the
    // request-attempt completion event keeps its established ordering.
    match (event) {
        case ModelEvent.Completed => None
        case _ => modelEventReplayBarrier(event)
    }
}

func providerStreamEventValue(event: ProviderStreamEvent): Array<ValueField> {
    match (event) {
        case ProviderStreamEvent.StreamStarted(kind) => [
            ValueField("code", textValue("model.stream_started")),
            ValueField("terminal_event_kind", textValue(kind))
        ]
        case ProviderStreamEvent.ControlledFaultInjected(profileId, attemptOrdinal) => [
            ValueField("code", textValue("model.controlled_fault_injected")),
            ValueField("fault_profile_id", textValue(profileId)),
            ValueField("fault_attempt_ordinal", integerValue(attemptOrdinal))
        ]
        case ProviderStreamEvent.ContentBlockStarted(index, kind) => [
            ValueField("code", textValue("model.content_block_started")),
            ValueField("block_index", integerValue(index)),
            ValueField("block_kind", textValue(kind))
        ]
        case ProviderStreamEvent.ContentBlockCompleted(index, kind) => [
            ValueField("code", textValue("model.content_block_completed")),
            ValueField("block_index", integerValue(index)),
            ValueField("block_kind", textValue(kind))
        ]
        case ProviderStreamEvent.MessageTerminalObserved(evidence) => [
            ValueField("code", textValue("model.message_terminal_observed")),
            ValueField("protocol", textValue(evidence.protocol)),
            ValueField("terminal_event_kind", textValue(evidence.terminalEventKind)),
            ValueField("raw_stop_reason", textValue(evidence.rawStopReason)),
            ValueField("adapter_version", textValue(evidence.adapterVersion))
        ]
        case ProviderStreamEvent.UsageDelta(input, output) => [
            ValueField("code", textValue("model.usage_delta")),
            ValueField("input_tokens", integerValue(input)),
            ValueField("output_tokens", integerValue(output))
        ]
        case ProviderStreamEvent.UsageCompleted(input, output) => [
            ValueField("code", textValue("model.usage_completed")),
            ValueField("input_tokens", integerValue(input)),
            ValueField("output_tokens", integerValue(output))
        ]
        case ProviderStreamEvent.ProviderError(message) => [
            ValueField("code", textValue("model.provider_error")),
            ValueField("message", textValue(message))
        ]
        case ProviderStreamEvent.StreamTransportClosed => [
            ValueField("code", textValue("model.stream_transport_closed"))
        ]
    }
}

class AgentCoreInternalModelBudgetController <: InternalModelBudgetController {
    private let core: AgentCore

    init(core: AgentCore) { this.core = core }

    public func executeCanonicalInternal(request: ModelRequest, options: InternalModelCallOptions,
        events: ModelEventSink): Result<ModelReply> {
        core.executeCanonicalInternal(request, options, events)
    }

    public func reserveInternalModelRequest(
        parent: AgentRunRequest
    ): Result<Unit> {
        core.reserveInternalModelRequest(parent)
    }

    public func accountInternalModelUsage(
        parent: AgentRunRequest,
        usage: ModelUsage
    ): Result<Unit> {
        core.accountInternalModelUsage(parent, usage)
    }
}
