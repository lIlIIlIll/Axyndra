package agent_core

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.sync.*
import std.time.*

public enum ModelAttemptRecoveryMode {
    Disabled | RecoveryV1
}

// RecoveryV1 is idle-based. Active reasoning, text, and tool-call streaming
// may run until the Run wall budget is exhausted; only a stream that stops
// making meaningful progress is abandoned and replayed once.
public class ModelAttemptRecoveryPolicy {
    public let mode: ModelAttemptRecoveryMode
    public let attemptTimeoutMillis: Int64
    public let maxRecoveryRetries: Int64
    public let hardTimeoutMillis: Int64
    public let streamIdleMillis: Int64
    public let recentProgressMillis: Int64

    public init(
        mode!: ModelAttemptRecoveryMode = ModelAttemptRecoveryMode.RecoveryV1,
        attemptTimeoutMillis!: Int64 = 0,
        maxRecoveryRetries!: Int64 = 1,
        hardTimeoutMillis!: Int64 = 0,
        streamIdleMillis!: Int64 = 120000,
        recentProgressMillis!: Int64 = 1000
    ) {
        let noWholeAttemptDeadline = attemptTimeoutMillis == 0 && hardTimeoutMillis == 0
        let validFiniteDeadline = attemptTimeoutMillis > 0 &&
            (hardTimeoutMillis == 0 || hardTimeoutMillis >= attemptTimeoutMillis)
        if ((!noWholeAttemptDeadline && !validFiniteDeadline) || maxRecoveryRetries < 0 ||
            maxRecoveryRetries > 1 || (hardTimeoutMillis > 0 &&
                hardTimeoutMillis < attemptTimeoutMillis) ||
            streamIdleMillis < 1 || recentProgressMillis < 1) {
            throw IllegalArgumentException("model attempt recovery limits are out of range")
        }
        this.mode = mode
        this.attemptTimeoutMillis = attemptTimeoutMillis
        this.maxRecoveryRetries = maxRecoveryRetries
        this.hardTimeoutMillis = if (attemptTimeoutMillis == 0) {
            0
        } else if (hardTimeoutMillis > 0) {
            hardTimeoutMillis
        } else { attemptTimeoutMillis + 30000 }
        this.streamIdleMillis = streamIdleMillis
        this.recentProgressMillis = recentProgressMillis
    }

    public func enabled(): Bool {
        match (mode) {
            case ModelAttemptRecoveryMode.RecoveryV1 => true
            case ModelAttemptRecoveryMode.Disabled => false
        }
    }
}

// Online attempt timing is deliberately process-local. Implementations expose
// only an arbitrary monotonic millisecond origin; no value from this clock is
// ever persisted or compared across processes.
public interface AttemptMonotonicClock {
    func nowMillis(): Int64
}

public class SystemAttemptMonotonicClock <: AttemptMonotonicClock {
    private let origin = MonoTime.now()
    public init() {}
    public func nowMillis(): Int64 {
        max(0, (MonoTime.now() - origin).toMilliseconds())
    }
}

// Deterministic clock for contract tests. Runtime code receives the same
// interface, making deadline tests independent of sleep and wall-clock time.
public class ManualAttemptMonotonicClock <: AttemptMonotonicClock {
    private let lock = Mutex()
    private var value: Int64
    public init(startMillis!: Int64 = 0) { value = max(0, startMillis) }
    public func nowMillis(): Int64 {
        lock.lock()
        try { value } finally { lock.unlock() }
    }
    public func advance(millis: Int64): Unit {
        if (millis < 0) { throw IllegalArgumentException("monotonic clock cannot move backwards") }
        lock.lock()
        try { value += millis } finally { lock.unlock() }
    }
}

@Derive[Equatable]
public enum AttemptDeadlineAction {
    Continue
    | EnterDecisionCompletionGrace
    | SoftDeadlineExceeded
    | HardDeadlineExceeded
    | StreamIdle
    | ReasoningRestartedInGrace
}

// RecoveryV1 deliberately has no whole-attempt deadline. The compatibility action
// variants remain public for persisted diagnostics/source compatibility, but
// this context only emits Continue or StreamIdle.
public class AttemptDeadlineContext {
    private let lock = Mutex()
    private let clock: AttemptMonotonicClock
    private let started: Int64
    private let idleBudget: Int64
    private var lastProgressAt: Int64
    private var lastKind = AttemptProgressKind.NoProgress
    private var meaningfulCount: Int64 = 0
    private var openBlocks: Int64 = 0
    private var callsStarted: Int64 = 0
    private var callsCompleted: Int64 = 0
    private var terminalSeen = false
    private var accepting = true
    private var replayBarrier = ModelAttemptReplayBarrier.NoBarrier
    private var persistenceFailure: ?AgentError = None

    public init(
        policy: ModelAttemptRecoveryPolicy,
        clock: AttemptMonotonicClock,
        idleLimitMillis!: Int64 = 0
    ) {
        this.clock = clock
        started = clock.nowMillis()
        idleBudget = if (idleLimitMillis > 0) {
            min(policy.streamIdleMillis, idleLimitMillis)
        } else { policy.streamIdleMillis }
        lastProgressAt = started
    }

    public func record(event: ModelEvent): Bool {
        lock.lock()
        try {
            if (!accepting) { return false }
            let now = clock.nowMillis()
            match (event) {
                case ModelEvent.ReasoningDelta(value) => if (value != "") {
                    progress(AttemptProgressKind.ReasoningProgress, now)
                }
                case ModelEvent.TextDelta(value) => if (value != "") {
                    progress(AttemptProgressKind.TextProgress, now)
                }
                case ModelEvent.ToolCallStarted(_, _) =>
                    callsStarted += 1
                    progress(AttemptProgressKind.ToolCallStartedProgress, now)
                case ModelEvent.ToolArgumentsDelta(_, value) => if (value != "") {
                    progress(AttemptProgressKind.ToolArgumentProgress, now)
                }
                case ModelEvent.ToolCallCompleted(_) => callsCompleted += 1
                case ModelEvent.ProviderProgress(value) => match (value) {
                    case ProviderStreamEvent.ContentBlockStarted(_, _) => openBlocks += 1
                    case ProviderStreamEvent.ContentBlockCompleted(_, _) =>
                        openBlocks = max(0, openBlocks - 1)
                        progress(AttemptProgressKind.ContentBlockCompletedProgress, now)
                    case ProviderStreamEvent.MessageTerminalObserved(_) =>
                        terminalSeen = true
                        progress(AttemptProgressKind.ProviderTerminalProgress, now)
                    case _ => () // heartbeat/usage/EOF are not meaningful progress
                }
                case _ => ()
            }
            true
        } finally { lock.unlock() }
    }

    private func progress(kind: AttemptProgressKind, now: Int64): Unit {
        lastKind = kind
        lastProgressAt = now
        meaningfulCount += 1
    }

    public func evaluate(): AttemptDeadlineAction {
        lock.lock()
        try {
            let now = clock.nowMillis()
            if (max(0, now - lastProgressAt) >= idleBudget) {
                return AttemptDeadlineAction.StreamIdle
            }
            AttemptDeadlineAction.Continue
        } finally { lock.unlock() }
    }

    public func diagnostics(): AttemptFailureDiagnostics {
        lock.lock()
        try {
            let now = clock.nowMillis()
            AttemptFailureDiagnostics(
                elapsedMillis: max(0, now - started),
                softDeadlineMillis: 0,
                hardDeadlineMillis: 0,
                enteredCompletionGrace: false,
                lastProgressKind: lastKind,
                lastProgressAgeMillis: max(0, now - lastProgressAt),
                providerTerminalObserved: terminalSeen,
                openContentBlockCount: openBlocks,
                toolCallsStarted: callsStarted,
                toolCallsCompleted: callsCompleted
            )
        } finally { lock.unlock() }
    }

    public func hasEvents(): Bool {
        lock.lock()
        try { meaningfulCount > 0 } finally { lock.unlock() }
    }
    public func completedObserved(): Bool {
        lock.lock()
        try { terminalSeen } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try { accepting = false } finally { lock.unlock() }
    }

    // The first non-replay-safe observation owns the durable barrier. Later
    // observations may add telemetry but never rewrite that recovery fact.
    public func claimReplayBarrier(value: ModelAttemptReplayBarrier): Bool {
        lock.lock()
        try {
            if (replayBarrier != ModelAttemptReplayBarrier.NoBarrier) { return false }
            replayBarrier = value
            true
        } finally { lock.unlock() }
    }

    public func persistFirstReplayBarrier(
        value: ModelAttemptReplayBarrier,
        persist: () -> Result<Unit>
    ): Result<Unit> {
        lock.lock()
        try {
            if (replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                return match (persistenceFailure) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            match (persist()) {
                case Result.Ok(_) =>
                    replayBarrier = value
                    Result.Ok(())
                case Result.Err(error) =>
                    persistenceFailure = Some(error)
                    Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    public func observedReplayBarrier(): ModelAttemptReplayBarrier {
        lock.lock()
        try { replayBarrier } finally { lock.unlock() }
    }

    public func recordPersistenceFailure(error: AgentError): Unit {
        lock.lock()
        try {
            if (persistenceFailure.isNone()) { persistenceFailure = Some(error) }
        } finally { lock.unlock() }
    }

    public func persistenceError(): ?AgentError {
        lock.lock()
        try { persistenceFailure } finally { lock.unlock() }
    }
}

@Derive[Equatable]
public enum AttemptRetryDisposition {
    RetrySamePolicy | RetryEscalated | DoNotRetry | ResumeDurableDecision
}

public func retryDisposition(error: AgentError, durableDecisionExists: Bool): AttemptRetryDisposition {
    if (durableDecisionExists) { return AttemptRetryDisposition.ResumeDurableDecision }
    match (error.attemptFailure) {
        case Some(failure) => match (failure.kind) {
            case AttemptFailureKind.UserCancelled | AttemptFailureKind.RunDeadlineExceeded |
                 AttemptFailureKind.ProviderProtocolError => AttemptRetryDisposition.DoNotRetry
            case AttemptFailureKind.StreamIdleTimeout |
                 AttemptFailureKind.AttemptSoftDeadlineExceeded |
                 AttemptFailureKind.AttemptHardDeadlineExceeded |
                 AttemptFailureKind.DecisionIncompleteAtDeadline => AttemptRetryDisposition.RetrySamePolicy
            case _ => if (error.retryable) {
                AttemptRetryDisposition.RetrySamePolicy
            } else { AttemptRetryDisposition.DoNotRetry }
        }
        case None => if (error.kind == AgentErrorKind.Cancelled || !error.retryable) {
            AttemptRetryDisposition.DoNotRetry
        } else { AttemptRetryDisposition.RetrySamePolicy }
    }
}

public func retryDispositionForAttempt(
    error: AgentError,
    durableDecisionExists: Bool
): AttemptRetryDisposition {
    retryDisposition(error, durableDecisionExists)
}

// All host-side model consumers share this control plane. AgentCore keeps its
// turn-aware budget/event policy around execute(), while auxiliary calls use
// executeInternal() so they cannot bypass retry, timeout, cancellation, or a
// parent run's durable request/usage/cost counters.
public class InternalModelCallOptions {
    public let timeoutMillis: Int64
    public let maxAttempts: Int64
    public let parent: ?AgentRunRequest

    public init(
        timeoutMillis!: Int64 = 30000,
        maxAttempts!: Int64 = 2,
        parent!: ?AgentRunRequest = None
    ) {
        if (timeoutMillis < 1 || maxAttempts < 1 || maxAttempts > 8) {
            throw IllegalArgumentException("internal model call limits are out of range")
        }
        this.timeoutMillis = timeoutMillis
        this.maxAttempts = maxAttempts
        this.parent = parent
    }
}

public class ControlledModelPort <: ModelPort {
    private let provider: ModelPort
    private let runs: ?RunRepository
    private let budgetLock = Mutex()

    public init(provider: ModelPort, runs!: ?RunRepository = None) {
        this.provider = provider
        this.runs = runs
    }

    // AgentCore is the caller for ordinary turns and layers its run-state,
    // execution-ledger, idle timer, and typed events around this wire call.
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        provider.execute(request, events)
    }

    public func cancel(requestId: String): Result<Unit> {
        provider.cancel(requestId)
    }

    public func executeInternal(
        request: ModelRequest,
        options: InternalModelCallOptions,
        events!: ModelEventSink = {_ => ()}
    ): Result<ModelReply> {
        if (!request.tools.isEmpty() || request.parallelToolCalls ||
            match (request.toolChoice) {
                case ModelToolChoice.NoTools => false
                case _ => true
            }) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.internal_tools_forbidden",
                "internal model calls must explicitly disable tools and parallel tool generation"
            ))
        }
        if (options.parent.isSome() && runs.isSome() &&
            request.requestId.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.internal_request_id_required",
                "durable internal model calls require a request id"
            ))
        }
        let started = MonoTime.now()
        var attempt: Int64 = 1
        while (attempt <= options.maxAttempts) {
            match (internalParentGuard(options.parent, started)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (chargeAttempt(options.parent)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let activity = InternalModelActivity()
            let future = spawn {
                provider.execute(request, { event =>
                    if (activity.record()) { events(event) }
                })
            }
            while (future.tryGet().isNone()) {
                match (internalParentGuard(
                    options.parent,
                    started,
                    checkRunState: false
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        activity.close()
                        let _ = provider.cancel(request.requestId)
                        var cleanupWaited: Int64 = 0
                        while (future.tryGet().isNone() && cleanupWaited < 250) {
                            sleep(Duration.millisecond * 10)
                            cleanupWaited += 10
                        }
                        match (recordInternalAttempt(
                            options.parent,
                            request,
                            attempt,
                            error: Some(error)
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(recordError) => return Result.Err(recordError)
                        }
                        return Result.Err(error)
                }
                if ((MonoTime.now() - started).toMilliseconds() >= options.timeoutMillis) {
                    activity.close()
                    let _ = provider.cancel(request.requestId)
                    var cleanupWaited: Int64 = 0
                    while (future.tryGet().isNone() && cleanupWaited < 250) {
                        sleep(Duration.millisecond * 10)
                        cleanupWaited += 10
                    }
                    let timeout = AgentError(
                        AgentErrorKind.Timeout,
                        "model.internal_timeout",
                        "internal model call exceeded its bounded deadline",
                        retryable: false,
                        fields: [
                            ErrorField("request_id", request.requestId),
                            ErrorField("timeout_ms", options.timeoutMillis.toString())
                        ]
                    )
                    match (recordInternalAttempt(
                        options.parent,
                        request,
                        attempt,
                        error: Some(timeout)
                    )) {
                        case Result.Ok(_) => return Result.Err(timeout)
                        case Result.Err(recordError) => return Result.Err(recordError)
                    }
                }
                sleep(Duration.millisecond * 10)
            }
            activity.close()
            match (future.get()) {
                case Result.Ok(reply) =>
                    let charged = chargeReply(
                        options.parent,
                        request,
                        reply,
                        started
                    )
                    match (recordInternalAttempt(
                        options.parent,
                        request,
                        attempt,
                        reply: Some(reply)
                    )) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) => match (charged) {
                            case Result.Ok(_) => return Result.Ok(reply)
                            case Result.Err(error) => return Result.Err(error)
                        }
                    }
                case Result.Err(error) =>
                    let normalized = if (error.retryable && activity.hasEvents()) {
                        let fields = ArrayList<ErrorField>()
                        for (field in error.fields where field.name != "partial_stream") {
                            fields.add(field)
                        }
                        fields.add(ErrorField("partial_stream", "true"))
                        AgentError(
                            error.kind,
                            error.code,
                            error.message,
                            retryable: false,
                            fallbackAllowed: error.fallbackAllowed,
                            fields: fields.toArray()
                        )
                    } else {
                        error
                    }
                    match (recordInternalAttempt(
                        options.parent,
                        request,
                        attempt,
                        error: Some(normalized)
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(recordError) => return Result.Err(recordError)
                    }
                    if (!normalized.retryable || attempt == options.maxAttempts) {
                        return Result.Err(normalized)
                    }
                    let remaining = options.timeoutMillis -
                        (MonoTime.now() - started).toMilliseconds()
                    if (remaining <= 0) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Timeout,
                            "model.internal_timeout",
                            "internal model retry budget was exhausted",
                            retryable: false
                        ))
                    }
                    let requestedDelay = internalRetryDelayMillis(attempt, normalized)
                    let delay = if (remaining < requestedDelay) { remaining } else { requestedDelay }
                    match (waitForInternalRetry(options, started, delay)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
            }
            attempt += 1
        }
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "model.internal_retry_exhausted",
            "internal model call exhausted without a result"
        ))
    }

    private func chargeAttempt(parent: ?AgentRunRequest): Result<Unit> {
        match ((parent, runs)) {
            case (Some(request), Some(repository)) => withBudgetLock({=>
                let snapshot = match (repository.find(request.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                if (snapshot.modelRequests >= request.budget.maxModelRequests) {
                    return internalBudgetError<Unit>("model_requests")
                }
                repository.save(copyInternalSnapshot(
                    snapshot,
                    modelRequests: snapshot.modelRequests + 1
                ))
            })
            case _ => Result.Ok(())
        }
    }

    private func chargeReply(
        parent: ?AgentRunRequest,
        modelRequest: ModelRequest,
        reply: ModelReply,
        started: MonoTime
    ): Result<Unit> {
        match ((parent, runs)) {
            case (Some(request), Some(repository)) => withBudgetLock({=>
                let snapshot = match (repository.find(request.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                let inputExceeded = reply.inputTokens > request.budget.maxInputTokens
                let outputExceeded = reply.outputTokens > request.budget.maxOutputTokens
                let requestCost: ?Int64 = match (request.pricing) {
                    case Some(value) => priceModelUsage(reply.usage, value)
                    case None => None
                }
                let firstKnownUsage = snapshot.modelRequests == 1 &&
                    snapshot.inputTokens == 0 && snapshot.outputTokens == 0 &&
                    snapshot.reasoningTokens == 0 && snapshot.cacheReadTokens == 0 &&
                    snapshot.cacheWriteTokens == 0
                let totalCost: ?Int64 = if (firstKnownUsage) {
                    requestCost
                } else {
                    match ((snapshot.costMicros, requestCost)) {
                        case (Some(total), Some(value)) => Some(total + value)
                        case _ => None
                    }
                }
                let costExceeded = match (totalCost) {
                    case Some(value) => request.budget.maxCostMicros > 0 &&
                        value > request.budget.maxCostMicros
                    case None => false
                }
                let eventSequence = match (nextInternalEventSequence(
                    repository,
                    request.runId,
                    snapshot.sequence
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                match (repository.save(copyInternalSnapshot(
                    snapshot,
                    sequence: eventSequence,
                    inputTokens: snapshot.inputTokens + reply.inputTokens,
                    outputTokens: snapshot.outputTokens + reply.outputTokens,
                    reasoningTokens: snapshot.reasoningTokens + reply.reasoningTokens,
                    cacheReadTokens: snapshot.cacheReadTokens + reply.cacheReadTokens,
                    cacheWriteTokens: snapshot.cacheWriteTokens + reply.cacheWriteTokens,
                    costMicros: totalCost,
                    replaceCost: true,
                    lastInputTokens: reply.inputTokens,
                    lastOutputTokens: reply.outputTokens,
                    lastRequestDurationMillis: max(
                        0,
                        (MonoTime.now() - started).toMilliseconds()
                    )
                ))) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(_) => ()
                }
                let eventUsage = ModelUsage(
                    inputTokens: reply.inputTokens,
                    outputTokens: reply.outputTokens,
                    reasoningTokens: reply.reasoningTokens,
                    cacheReadTokens: reply.cacheReadTokens,
                    cacheWriteTokens: reply.cacheWriteTokens,
                    costMicros: match (requestCost) {
                        case Some(value) => Some(value)
                        case None => reply.usage.costMicros
                    }
                )
                match (repository.append(AgentEvent(
                    EventMeta(
                        eventSequence,
                        TraceId("internal-model-" + request.runId.value),
                        request.runId,
                        occurredAtMillis: agentUtcMillis(),
                        requestId: if (modelRequest.requestId == "") {
                            None
                        } else {
                            Some(RequestId(modelRequest.requestId))
                        }
                    ),
                    AgentEventPayload.ModelUsageUpdated(eventUsage)
                ))) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(_) => ()
                }
                if (inputExceeded) { return internalBudgetError<Unit>("input_tokens") }
                if (outputExceeded) { return internalBudgetError<Unit>("output_tokens") }
                if (costExceeded) { return internalBudgetError<Unit>("cost") }
                Result.Ok(())
            })
            case _ => Result.Ok(())
        }
    }

    private func recordInternalAttempt(
        parent: ?AgentRunRequest,
        modelRequest: ModelRequest,
        attempt: Int64,
        reply!: ?ModelReply = None,
        error!: ?AgentError = None
    ): Result<Unit> {
        match ((parent, runs)) {
            case (Some(request), Some(repository)) => withBudgetLock({=>
                let snapshot = match (repository.find(request.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(value) => return Result<Unit>.Err(value)
                }
                let sequence = match (nextInternalEventSequence(
                    repository,
                    request.runId,
                    snapshot.sequence
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(value) => return Result<Unit>.Err(value)
                }
                let value = match ((reply, error)) {
                    case (Some(value), None) => ModelRequestAttempt(
                        RequestId(modelRequest.requestId),
                        modelRequest.model,
                        attempt,
                        ModelRequestOutcome.Succeeded,
                        usage: Some(accountedModelAttemptUsage(
                            value,
                            request.pricing
                        ))
                    )
                    case (None, Some(value)) => ModelRequestAttempt(
                        RequestId(modelRequest.requestId),
                        modelRequest.model,
                        attempt,
                        if (value.kind == AgentErrorKind.Cancelled) {
                            ModelRequestOutcome.Cancelled
                        } else {
                            ModelRequestOutcome.Failed
                        },
                        errorCode: value.code
                    )
                    case _ => return Result<Unit>.Err(AgentError(
                        AgentErrorKind.Internal,
                        "model.internal_attempt_invalid",
                        "internal model attempt must have exactly one outcome"
                    ))
                }
                match (repository.save(copyInternalSnapshot(
                    snapshot,
                    sequence: sequence
                ))) {
                    case Result.Ok(_) => ()
                    case Result.Err(value) => return Result<Unit>.Err(value)
                }
                repository.append(AgentEvent(
                    EventMeta(
                        sequence,
                        TraceId("internal-model-" + request.runId.value),
                        request.runId,
                        occurredAtMillis: agentUtcMillis(),
                        requestId: Some(value.requestId)
                    ),
                    AgentEventPayload.ModelRequestAttemptCompleted(value)
                ))
            })
            case _ => Result.Ok(())
        }
    }

    private func withBudgetLock<T>(action: () -> Result<T>): Result<T> {
        budgetLock.lock()
        try { action() } finally { budgetLock.unlock() }
    }

    private func waitForInternalRetry(
        options: InternalModelCallOptions,
        started: MonoTime,
        delayMillis: Int64
    ): Result<Unit> {
        let bounded = min(max(0, delayMillis), 8000)
        let waitStarted = MonoTime.now()
        var lastRunStateCheck: Int64 = -100
        while (true) {
            let elapsed = (MonoTime.now() - waitStarted).toMilliseconds()
            let checkRunState = elapsed - lastRunStateCheck >= 100
            match (internalParentGuard(
                options.parent,
                started,
                checkRunState: checkRunState
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            if (checkRunState) { lastRunStateCheck = elapsed }
            let totalElapsed = (MonoTime.now() - started).toMilliseconds()
            if (totalElapsed >= options.timeoutMillis) {
                return Result.Err(AgentError(
                    AgentErrorKind.Timeout,
                    "model.internal_timeout",
                    "internal model retry budget was exhausted",
                    retryable: false
                ))
            }
            if (elapsed >= bounded) { return Result.Ok(()) }
            sleep(Duration.millisecond * min(10, bounded - elapsed))
        }
        Result.Ok(())
    }

    private func internalParentGuard(
        parent: ?AgentRunRequest,
        started: MonoTime,
        checkRunState!: Bool = true
    ): Result<Unit> {
        match (parent) {
            case None => Result.Ok(())
            case Some(request) =>
                if (request.budget.deadlineMillis > 0 &&
                    agentUtcMillis() >= request.budget.deadlineMillis) {
                    return Result.Err(AgentError(
                        AgentErrorKind.BudgetExceeded,
                        "budget.deadline_exceeded",
                        "internal model call exceeded the parent run deadline",
                        fields: [ErrorField(
                            "deadline_millis",
                            request.budget.deadlineMillis.toString()
                        )]
                    ))
                }
                if (request.budget.maxWallMillis > 0 &&
                    (MonoTime.now() - started).toMilliseconds() >=
                    request.budget.maxWallMillis) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Timeout,
                        "model.internal_wall_timeout",
                        "internal model call exceeded the parent wall-clock budget",
                        fields: [ErrorField(
                            "timeout_ms",
                            request.budget.maxWallMillis.toString()
                        )]
                    ))
                }
                if (!checkRunState) { return Result.Ok(()) }
                match (runs) {
                    case Some(repository) => match (repository.find(request.runId)) {
                        case Result.Ok(snapshot) =>
                            if (snapshot.status == RunState.Cancelling ||
                                snapshot.status == RunState.Cancelled) {
                                Result.Err(AgentError(
                                    AgentErrorKind.Cancelled,
                                    "run.cancelled",
                                    "parent run was cancelled during an internal model call"
                                ))
                            } else {
                                Result.Ok(())
                            }
                        case Result.Err(error) => Result.Err(error)
                    }
                    case None => Result.Ok(())
                }
        }
    }
}

class InternalModelActivity {
    private let lock = Mutex()
    private var accepting = true
    private var eventCount: Int64 = 0

    func record(): Bool {
        lock.lock()
        try {
            if (!accepting) { return false }
            eventCount += 1
            true
        } finally { lock.unlock() }
    }

    func hasEvents(): Bool {
        lock.lock()
        try { eventCount > 0 } finally { lock.unlock() }
    }

    func close(): Unit {
        lock.lock()
        try { accepting = false } finally { lock.unlock() }
    }
}

func copyInternalSnapshot(
    value: RunSnapshot,
    sequence!: Int64 = -1,
    modelRequests!: Int64 = -1,
    inputTokens!: Int64 = -1,
    outputTokens!: Int64 = -1,
    reasoningTokens!: Int64 = -1,
    cacheReadTokens!: Int64 = -1,
    cacheWriteTokens!: Int64 = -1,
    costMicros!: ?Int64 = None,
    replaceCost!: Bool = false,
    lastInputTokens!: Int64 = -1,
    lastOutputTokens!: Int64 = -1,
    lastRequestDurationMillis!: Int64 = -1
): RunSnapshot {
    RunSnapshot(
        value.runId,
        value.sessionId,
        value.status,
        sequence: if (sequence >= 0) { sequence } else { value.sequence },
        summary: value.summary,
        error: value.error,
        modelRequests: if (modelRequests >= 0) { modelRequests } else { value.modelRequests },
        inputTokens: if (inputTokens >= 0) { inputTokens } else { value.inputTokens },
        outputTokens: if (outputTokens >= 0) { outputTokens } else { value.outputTokens },
        reasoningTokens: if (reasoningTokens >= 0) { reasoningTokens } else { value.reasoningTokens },
        cacheReadTokens: if (cacheReadTokens >= 0) { cacheReadTokens } else { value.cacheReadTokens },
        cacheWriteTokens: if (cacheWriteTokens >= 0) { cacheWriteTokens } else { value.cacheWriteTokens },
        costMicros: if (replaceCost) { costMicros } else { value.costMicros },
        lastInputTokens: if (lastInputTokens >= 0) { lastInputTokens } else { value.lastInputTokens },
        lastOutputTokens: if (lastOutputTokens >= 0) { lastOutputTokens } else { value.lastOutputTokens },
        lastRequestDurationMillis: if (lastRequestDurationMillis >= 0) {
            lastRequestDurationMillis
        } else { value.lastRequestDurationMillis },
        toolCalls: value.toolCalls,
        turns: value.turns,
        structuredOutput: value.structuredOutput,
        kind: value.kind
    )
}

func nextInternalEventSequence(
    repository: RunRepository,
    runId: RunId,
    snapshotSequence: Int64
): Result<Int64> {
    match (repository.events(runId, 0)) {
        case Result.Ok(page) => Result.Ok(max(snapshotSequence + 1, page.nextSequence))
        case Result.Err(error) => Result.Err(error)
    }
}

func internalRetryDelayMillis(attempt: Int64, error: AgentError): Int64 {
    match (error.field("retry_after_ms")) {
        case Some(value) => try {
            let parsed = Int64.parse(value)
            if (parsed > 0) { return min(parsed, 8000) }
        } catch (_: Exception) { () }
        case None => ()
    }
    var delay: Int64 = 500
    var remaining = max(1, attempt) - 1
    while (remaining > 0 && delay < 8000) {
        delay = min(delay * 2, 8000)
        remaining -= 1
    }
    delay
}

func internalBudgetError<T>(resource: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.BudgetExceeded,
        "run.budget_exceeded",
        "internal model call would exceed the parent run budget",
        fields: [ErrorField("resource", resource)]
    ))
}

func accountedModelAttemptUsage(
    reply: ModelReply,
    pricing: ?ModelPricing
): ModelUsage {
    ModelUsage(
        inputTokens: reply.inputTokens,
        outputTokens: reply.outputTokens,
        reasoningTokens: reply.reasoningTokens,
        cacheReadTokens: reply.cacheReadTokens,
        cacheWriteTokens: reply.cacheWriteTokens,
        costMicros: match (pricing) {
            case Some(value) => priceModelUsage(reply.usage, value)
            case None => reply.usage.costMicros
        }
    )
}
