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
    public func isProvisionalOutput(event: ModelEvent): Bool {
        match (event) {
            case ModelEvent.TextDelta(_) | ModelEvent.ReasoningDelta(_) => true
            case _ => false
        }
    }
    public func takeProvisionalOutput(): Array<ModelEvent> {
        // Provisional deltas are forwarded at observation time. Do not retain
        // an unbounded copy of a long provider stream just to replay it after
        // the attempt has completed.
        []
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
                 AttemptFailureKind.DecisionIncompleteAtDeadline |
                 AttemptFailureKind.MalformedToolArguments => AttemptRetryDisposition.RetrySamePolicy
            case AttemptFailureKind.OutputLimitedBeforeDecision |
                 AttemptFailureKind.OutputLimited => AttemptRetryDisposition.RetryEscalated
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
interface InternalModelBudgetController {
    func reserveInternalModelRequest(parent: AgentRunRequest): Result<Unit>
    func accountInternalModelUsage(parent: AgentRunRequest, usage: ModelUsage): Result<Unit>
}

public class InternalModelCallOptions {
    public let timeoutMillis: Int64
    public let maxAttempts: Int64
    public let parent: ?AgentRunRequest
    public let standaloneAccounting: Bool

    public init(
        timeoutMillis!: Int64 = 30000,
        maxAttempts!: Int64 = 2,
        parent!: ?AgentRunRequest = None,
        standaloneAccounting!: Bool = false
    ) {
        if (timeoutMillis < 1 || maxAttempts < 1 || maxAttempts > 8) {
            throw IllegalArgumentException("internal model call limits are out of range")
        }
        this.timeoutMillis = timeoutMillis
        this.maxAttempts = maxAttempts
        if (standaloneAccounting && parent.isNone()) {
            throw IllegalArgumentException("standalone accounting requires an explicit budget context")
        }
        this.parent = parent
        this.standaloneAccounting = standaloneAccounting
    }
}

public class ControlledModelPort <: ModelPort {
    private let provider: ModelPort
    private let runs: ?RunRepository
    private let budgetLock = Mutex()
    private var budgetController: ?InternalModelBudgetController = None

    public init(provider: ModelPort, runs!: ?RunRepository = None) {
        this.provider = provider
        this.runs = runs
    }

    func bindBudgetController(controller: InternalModelBudgetController): Unit {
        budgetLock.lock()
        try { budgetController = Some(controller) } finally { budgetLock.unlock() }
    }

    private func boundBudgetController(): ?InternalModelBudgetController {
        budgetLock.lock()
        try { budgetController } finally { budgetLock.unlock() }
    }

    // AgentCore is the caller for ordinary turns and layers its run-state,
    // execution-ledger, idle timer, and typed events around this wire call.
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        provider.execute(request, events)
    }

    public func transcriptSnapshot(request: ModelRequest): ?String {
        provider.transcriptSnapshot(request)
    }

    public func validateTranscriptSnapshot(snapshot: String): Bool {
        provider.validateTranscriptSnapshot(snapshot)
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
        if (options.parent.isNone() && !options.standaloneAccounting) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.internal_budget_context_required",
                "internal model calls require a live Run budget or explicit standalone accounting"
            ))
        }
        let runBudgetController = boundBudgetController()
        if (options.parent.isSome() && !options.standaloneAccounting &&
            runBudgetController.isNone()) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.internal_run_control_required",
                "internal Run model calls must use the canonical Run budget controller"
            ))
        }
        // Standalone maintenance has no canonical Run. Its explicit ledger is
        // call-local; missing durable parents never fall back to this mode.
        let standalone: ?StandaloneInternalLedger = if (options.standaloneAccounting) {
            Some(StandaloneInternalLedger(options.parent.getOrThrow()))
        } else { None }
        let accountingParent: ?AgentRunRequest = if (options.standaloneAccounting) { None } else { options.parent }
        let started = MonoTime.now()
        var attempt: Int64 = 1
        while (attempt <= options.maxAttempts) {
            match (internalParentGuard(options.parent, started, checkRunState: !options.standaloneAccounting)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let attemptCharge = match (standalone) {
                case Some(ledger) => ledger.chargeAttempt()
                case None => match ((options.parent, runBudgetController)) {
                    case (Some(parent), Some(controller)) =>
                        match (controller.reserveInternalModelRequest(parent)) {
                            case Result.Err(error) => Result<Unit>.Err(error)
                            case Result.Ok(_) => chargeAttempt(
                                accountingParent, canonicalBudget: true
                            )
                        }
                    case _ => Result<Unit>.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "model.internal_run_control_required",
                        "internal Run model calls must use the canonical Run budget controller"
                    ))
                }
            }
            match (attemptCharge) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let activity = InternalModelActivity()
            let future = spawn {
                provider.execute(request, { event =>
                    if (activity.record(event)) { events(event) }
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
                        let completed = future.tryGet()
                        let completedUsage = usageFromCompletedCall(
                            completed, options.parent
                        )
                        let observedUsage = match (completedUsage) {
                            case Some(value) => Some(value)
                            case None => activity.observedUsage()
                        }
                        let usageCharge = chargeObservedAttemptUsage(
                            accountingParent, request, observedUsage, started,
                            standalone, runBudgetController
                        )
                        let attemptRecord = recordInternalAttempt(
                            accountingParent, request, attempt,
                            error: Some(error), usage: observedUsage
                        )
                        if (completed.isNone()) {
                            settleLateInternalUsage(
                                future, activity, options.parent, accountingParent,
                                request, observedUsage, started, standalone,
                                runBudgetController
                            )
                        }
                        match (attemptRecord) {
                            case Result.Ok(_) => ()
                            case Result.Err(recordError) => return Result.Err(recordError)
                        }
                        match (usageCharge) {
                            case Result.Ok(_) => ()
                            case Result.Err(usageError) => return Result.Err(usageError)
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
                    let completed = future.tryGet()
                    let completedUsage = usageFromCompletedCall(
                        completed, options.parent
                    )
                    let observedUsage = match (completedUsage) {
                        case Some(value) => Some(value)
                        case None => activity.observedUsage()
                    }
                    let usageCharge = chargeObservedAttemptUsage(
                        accountingParent, request, observedUsage, started,
                        standalone, runBudgetController
                    )
                    let attemptRecord = recordInternalAttempt(
                        accountingParent, request, attempt,
                        error: Some(timeout), usage: observedUsage
                    )
                    if (completed.isNone()) {
                        settleLateInternalUsage(
                            future, activity, options.parent, accountingParent,
                            request, observedUsage, started, standalone,
                            runBudgetController
                        )
                    }
                    match (attemptRecord) {
                        case Result.Ok(_) => ()
                        case Result.Err(recordError) => return Result.Err(recordError)
                    }
                    match (usageCharge) {
                        case Result.Ok(_) => return Result.Err(timeout)
                        case Result.Err(usageError) => return Result.Err(usageError)
                    }
                }
                sleep(Duration.millisecond * 10)
            }
            activity.close()
            match (future.get()) {
                case Result.Ok(reply) =>
                    let charged = match (standalone) {
                        case Some(ledger) => ledger.chargeReply(reply)
                        case None => chargeReply(
                            accountingParent, request, reply, started,
                            runBudgetController.getOrThrow()
                        )
                    }
                    match (recordInternalAttempt(
                        accountingParent,
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
                    let providerUsage = attemptUsageFromError(
                        normalized,
                        match (options.parent) {
                            case Some(parent) => parent.pricing
                            case None => None
                        }
                    )
                    let observedUsage = match (providerUsage) {
                        case Some(value) => Some(value)
                        case None => activity.observedUsage()
                    }
                    let usageCharge = chargeObservedAttemptUsage(
                        accountingParent, request, observedUsage, started,
                        standalone, runBudgetController
                    )
                    match (recordInternalAttempt(
                        accountingParent,
                        request,
                        attempt,
                        error: Some(normalized),
                        usage: observedUsage
                    )) {
                        case Result.Ok(_) => ()
                        case Result.Err(recordError) => return Result.Err(recordError)
                    }
                    match (usageCharge) {
                        case Result.Ok(_) => ()
                        case Result.Err(usageError) => return Result.Err(usageError)
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

    private func usageFromCompletedCall(
        outcome: ?Result<ModelReply>,
        parent: ?AgentRunRequest
    ): ?ModelUsage {
        let pricing: ?ModelPricing = match (parent) {
            case Some(request) => request.pricing
            case None => None
        }
        match (outcome) {
            case Some(Result.Ok(reply)) =>
                Some(accountedModelAttemptUsage(reply, pricing))
            case Some(Result.Err(error)) => attemptUsageFromError(error, pricing)
            case None => None
        }
    }

    private func chargeObservedAttemptUsage(
        parent: ?AgentRunRequest,
        modelRequest: ModelRequest,
        usage: ?ModelUsage,
        started: MonoTime,
        standalone: ?StandaloneInternalLedger,
        budgetController: ?InternalModelBudgetController
    ): Result<Unit> {
        match (usage) {
            case Some(value) => match (standalone) {
                case Some(ledger) => ledger.chargeUsage(value)
                case None => chargeObservedUsage(
                    parent.getOrThrow(),
                    modelRequest,
                    value,
                    started,
                    budgetController.getOrThrow()
                )
            }
            case None => Result.Ok(())
        }
    }

    private func settleLateInternalUsage(
        future: Future<Result<ModelReply>>,
        activity: InternalModelActivity,
        parent: ?AgentRunRequest,
        accountingParent: ?AgentRunRequest,
        modelRequest: ModelRequest,
        chargedUsage: ?ModelUsage,
        started: MonoTime,
        standalone: ?StandaloneInternalLedger,
        budgetController: ?InternalModelBudgetController
    ): Unit {
        let _ = spawn {
            let completedUsage = usageFromCompletedCall(Some(future.get()), parent)
            let terminalUsage = match (completedUsage) {
                case Some(value) => Some(value)
                case None => activity.observedUsage()
            }
            match (internalModelUsageDelta(terminalUsage, chargedUsage)) {
                case Some(delta) =>
                    let _ = chargeObservedAttemptUsage(
                        accountingParent,
                        modelRequest,
                        Some(delta),
                        started,
                        standalone,
                        budgetController
                    )
                case None => ()
            }
        }
    }

    private func chargeAttempt(
        parent: ?AgentRunRequest,
        canonicalBudget!: Bool = false
    ): Result<Unit> {
        match ((parent, runs)) {
            case (Some(request), Some(repository)) => withBudgetLock({=>
                let snapshot = match (repository.find(request.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                if (!canonicalBudget &&
                    snapshot.modelRequests >= request.budget.maxModelRequests) {
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
        started: MonoTime,
        budgetController: InternalModelBudgetController
    ): Result<Unit> {
        let request = parent.getOrThrow()
        chargeObservedUsage(
            request,
            modelRequest,
            accountedModelAttemptUsage(reply, request.pricing),
            started,
            budgetController
        )
    }

    private func chargeObservedUsage(
        request: AgentRunRequest,
        modelRequest: ModelRequest,
        usage: ModelUsage,
        started: MonoTime,
        budgetController: InternalModelBudgetController
    ): Result<Unit> {
        let inputExceeded = usage.inputTokens > request.budget.maxInputTokens
        let outputExceeded = usage.outputTokens > request.budget.maxOutputTokens
        let durable = match (runs) {
            case Some(repository) => withBudgetLock({=>
                let snapshot = match (repository.find(request.runId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                let totalInput = saturatedModelUsageAdd(
                    snapshot.inputTokens, usage.inputTokens
                )
                let totalOutput = saturatedModelUsageAdd(
                    snapshot.outputTokens, usage.outputTokens
                )
                let totalCost: ?Int64 = match ((snapshot.costMicros, usage.costMicros)) {
                    case (Some(total), Some(value)) =>
                        Some(saturatedModelUsageAdd(total, value))
                    case (Some(total), None) => Some(total)
                    case (None, Some(value)) => Some(value)
                    case (None, None) => None
                }
                let eventSequence = match (nextInternalEventSequence(
                    repository, request.runId, snapshot.sequence
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                match (repository.save(copyInternalSnapshot(
                    snapshot,
                    sequence: eventSequence,
                    inputTokens: totalInput,
                    outputTokens: totalOutput,
                    reasoningTokens: saturatedModelUsageAdd(
                        snapshot.reasoningTokens, usage.reasoningTokens
                    ),
                    cacheReadTokens: saturatedModelUsageAdd(
                        snapshot.cacheReadTokens, usage.cacheReadTokens
                    ),
                    cacheWriteTokens: saturatedModelUsageAdd(
                        snapshot.cacheWriteTokens, usage.cacheWriteTokens
                    ),
                    costMicros: totalCost,
                    replaceCost: true,
                    lastInputTokens: usage.inputTokens,
                    lastOutputTokens: usage.outputTokens,
                    lastRequestDurationMillis: max(
                        0, (MonoTime.now() - started).toMilliseconds()
                    )
                ))) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(_) => ()
                }
                repository.append(AgentEvent(
                    EventMeta(
                        eventSequence,
                        TraceId("internal-model-" + request.runId.value),
                        request.runId,
                        occurredAtMillis: agentUtcMillis(),
                        requestId: if (modelRequest.requestId == "") {
                            None
                        } else { Some(RequestId(modelRequest.requestId)) }
                    ),
                    AgentEventPayload.ModelUsageUpdated(usage)
                ))
            })
            case None => Result.Ok(())
        }
        match (durable) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let budgetResult = budgetController.accountInternalModelUsage(
            request, usage
        )
        if (inputExceeded) { return internalBudgetError<Unit>("input_tokens") }
        if (outputExceeded) { return internalBudgetError<Unit>("output_tokens") }
        budgetResult
    }

    private func recordInternalAttempt(
        parent: ?AgentRunRequest,
        modelRequest: ModelRequest,
        attempt: Int64,
        reply!: ?ModelReply = None,
        error!: ?AgentError = None,
        usage!: ?ModelUsage = None
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
                        errorCode: value.code,
                        usage: usage
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
                checkRunState: checkRunState && !options.standaloneAccounting
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
    private var forwarding = true
    private var eventCount: Int64 = 0
    private var usageSeen = false
    private var inputTokens: Int64 = 0
    private var outputTokens: Int64 = 0

    func record(event: ModelEvent): Bool {
        lock.lock()
        try {
            let shouldForward = forwarding
            eventCount += 1
            match (event) {
                case ModelEvent.UsageUpdated(input, output) =>
                    inputTokens = input
                    outputTokens = output
                    usageSeen = true
                case ModelEvent.ProviderProgress(ProviderStreamEvent.UsageDelta(input, output)) =>
                    inputTokens = saturatedModelUsageAdd(inputTokens, input)
                    outputTokens = saturatedModelUsageAdd(outputTokens, output)
                    usageSeen = true
                case ModelEvent.ProviderProgress(ProviderStreamEvent.UsageCompleted(input, output)) =>
                    inputTokens = input
                    outputTokens = output
                    usageSeen = true
                case _ => ()
            }
            shouldForward
        } finally { lock.unlock() }
    }

    func observedUsage(): ?ModelUsage {
        lock.lock()
        try {
            if (!usageSeen) { return None }
            Some(ModelUsage(inputTokens: inputTokens, outputTokens: outputTokens))
        } finally { lock.unlock() }
    }

    func hasEvents(): Bool {
        lock.lock()
        try { eventCount > 0 } finally { lock.unlock() }
    }

    func close(): Unit {
        lock.lock()
        try { forwarding = false } finally { lock.unlock() }
    }
}

func internalModelUsageDelta(
    terminal: ?ModelUsage,
    charged: ?ModelUsage
): ?ModelUsage {
    let finalUsage = match (terminal) {
        case Some(value) => value
        case None => return None
    }
    let previous = match (charged) {
        case Some(value) => value
        case None => ModelUsage()
    }
    let cost: ?Int64 = match ((finalUsage.costMicros, previous.costMicros)) {
        case (Some(value), Some(already)) => Some(max(0, value - already))
        case (Some(value), None) => Some(value)
        case _ => None
    }
    let inputDelta = max(0, finalUsage.inputTokens - previous.inputTokens)
    let outputDelta = max(0, finalUsage.outputTokens - previous.outputTokens)
    let cacheReadDelta = min(
        max(0, finalUsage.cacheReadTokens - previous.cacheReadTokens),
        inputDelta
    )
    let cacheWriteDelta = min(
        max(0, finalUsage.cacheWriteTokens - previous.cacheWriteTokens),
        inputDelta - cacheReadDelta
    )
    let delta = ModelUsage(
        inputTokens: inputDelta,
        outputTokens: outputDelta,
        reasoningTokens: min(
            max(0, finalUsage.reasoningTokens - previous.reasoningTokens),
            outputDelta
        ),
        cacheReadTokens: cacheReadDelta,
        cacheWriteTokens: cacheWriteDelta,
        costMicros: cost
    )
    let noCost = match (cost) {
        case Some(value) => value == 0
        case None => true
    }
    if (delta.inputTokens == 0 && delta.outputTokens == 0 &&
        delta.reasoningTokens == 0 && delta.cacheReadTokens == 0 &&
        delta.cacheWriteTokens == 0 && noCost) {
        None
    } else {
        Some(delta)
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
    match (retryAfterMillisField(error)) {
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
        },
        source: reply.usage.source,
        evidence: reply.usage.evidence
    )
}

// Usage billed for an attempt whose provider call failed mid-flight or
// produced a rejected reply. The adapter surfaces what the wire showed
// before the failure as error fields; cost is priced the same way as a
// successful reply. None when the failure carried no observable usage.
func attemptUsageFromError(
    error: AgentError,
    pricing: ?ModelPricing
): ?ModelUsage {
    let inputField = error.field("usage_input_tokens")
    let outputField = error.field("usage_output_tokens")
    let reasoningField = error.field("usage_reasoning_tokens")
    let cacheReadField = error.field("usage_cache_read_tokens")
    let cacheWriteField = error.field("usage_cache_write_tokens")
    if (inputField.isNone() && outputField.isNone() && reasoningField.isNone() &&
        cacheReadField.isNone() && cacheWriteField.isNone()) { return None }
    let inputTokens = parseObservedUsageField(inputField)
    let outputTokens = parseObservedUsageField(outputField)
    let reasoningTokens = parseObservedUsageField(reasoningField)
    let cacheReadTokens = parseObservedUsageField(cacheReadField)
    let cacheWriteTokens = parseObservedUsageField(cacheWriteField)
    if (inputTokens.isNone() || outputTokens.isNone() || reasoningTokens.isNone() ||
        cacheReadTokens.isNone() || cacheWriteTokens.isNone()) { return None }
    let input = inputTokens.getOrThrow()
    let output = outputTokens.getOrThrow()
    let reasoning = reasoningTokens.getOrThrow()
    let cacheRead = cacheReadTokens.getOrThrow()
    let cacheWrite = cacheWriteTokens.getOrThrow()
    if (cacheRead > Int64.Max - cacheWrite ||
        cacheRead + cacheWrite > input || reasoning > output) { return None }
    Some(ModelUsage(
        inputTokens: input,
        outputTokens: output,
        reasoningTokens: reasoning,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: cacheWrite,
        costMicros: match (pricing) {
            case Some(value) => priceModelUsage(ModelUsage(
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            ), value)
            case None => None
        }
    ))
}

func parseObservedUsageField(value: ?String): ?Int64 {
    match (value) {
        case Some(text) => try {
            let parsed = Int64.parse(text)
            if (parsed < 0) { None } else { Some(parsed) }
        } catch (_: Exception) { None }
        case None => Some(0)
    }
}

class StandaloneInternalLedger {
    private let parent: AgentRunRequest
    private var requests: Int64 = 0
    private var input: Int64 = 0
    private var output: Int64 = 0
    private var cost: Int64 = 0

    init(parent: AgentRunRequest) { this.parent = parent }

    func chargeAttempt(): Result<Unit> {
        if (requests >= parent.budget.maxModelRequests) {
            return internalBudgetError<Unit>("model_requests")
        }
        requests += 1
        Result.Ok(())
    }

    func chargeReply(reply: ModelReply): Result<Unit> {
        chargeUsage(accountedModelAttemptUsage(reply, parent.pricing))
    }

    func chargeUsage(usage: ModelUsage): Result<Unit> {
        input = saturatedModelUsageAdd(input, usage.inputTokens)
        output = saturatedModelUsageAdd(output, usage.outputTokens)
        let valueCost = match (usage.costMicros) {
            case Some(value) => value
            case None => 0
        }
        cost = saturatedModelUsageAdd(cost, valueCost)
        let budget = parent.budget
        if (usage.inputTokens > budget.maxInputTokens) { return internalBudgetError<Unit>("input_tokens") }
        if (usage.outputTokens > budget.maxOutputTokens) { return internalBudgetError<Unit>("output_tokens") }
        if (budget.maxTotalInputTokens > 0 && input > budget.maxTotalInputTokens) {
            return internalBudgetError<Unit>("total_input_tokens")
        }
        if (budget.maxTotalOutputTokens > 0 && output > budget.maxTotalOutputTokens) {
            return internalBudgetError<Unit>("total_output_tokens")
        }
        if (budget.maxCostMicros > 0 && cost > budget.maxCostMicros) {
            return internalBudgetError<Unit>("cost")
        }
        Result.Ok(())
    }
}
class ModelAttemptRequestPlan {
    let attemptNo: Int64
    let parentAttemptId: ?ModelAttemptId
    let attemptId: ModelAttemptId
    let policy: AttemptPolicy
    let request: ModelRequest

    init(
        attemptNo: Int64,
        parentAttemptId: ?ModelAttemptId,
        attemptId: ModelAttemptId,
        policy: AttemptPolicy,
        request: ModelRequest
    ) {
        this.attemptNo = attemptNo
        this.parentAttemptId = parentAttemptId
        this.attemptId = attemptId
        this.policy = policy
        this.request = request
    }
}

// Resolve policy once, then freeze the transport identity and effective request
// before the caller persists or dispatches the attempt. The retry loop remains
// in AgentCore; this planner has no retry or persistence authority.
func prepareModelAttemptRequest(
    runRequest: AgentRunRequest,
    modelRequest: ModelRequest,
    semanticRequestId: SemanticModelRequestId,
    attemptNo: Int64,
    reason: AttemptPolicyReason,
    recovery: ModelAttemptRecoveryPolicy,
    recoveryCeiling!: ?ThinkingLevel = None,
    parentAttemptId!: ?ModelAttemptId = None
): Result<ModelAttemptRequestPlan> {
    let attemptRequest = modelRequestForAttempt(modelRequest, attemptNo)
    let resolved = match (resolvedModelRequestForAttempt(
        runRequest, attemptRequest, recoveryCeiling: recoveryCeiling
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let policy = attemptPolicyFor(resolved, reason, recovery)
    let effectiveRequest = requestFromAttemptPolicy(resolved, policy)
    Result.Ok(ModelAttemptRequestPlan(
        attemptNo,
        parentAttemptId,
        modelAttemptIdFor(semanticRequestId, attemptNo),
        policy,
        effectiveRequest
    ))
}

func resolvedModelRequestForAttempt(
    runRequest: AgentRunRequest,
    request: ModelRequest,
    recoveryCeiling!: ?ThinkingLevel = None
): Result<ModelRequest> {
    let resolved = match (resolveModelAttemptPolicy(AttemptPolicyInput(
        runRequest.requestedPolicy,
        runRequest.modelCapabilitiesSnapshot,
        recoveryCeiling: recoveryCeiling,
        resolverVersion: runRequest.resolverVersion
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(ModelRequest(
        request.model,
        request.messages,
        system: request.system,
        tools: request.tools,
        thinking: resolved.thinking.effective,
        maxOutputTokens: resolved.output.effectiveWireLimit,
        wireMaxOutputTokens: Some(resolved.output.effectiveWireLimit),
        resolvedPolicy: Some(resolved),
        streaming: request.streaming,
        parallelToolCalls: request.parallelToolCalls,
        requestId: request.requestId,
        serviceTier: request.serviceTier,
        cachePolicy: request.cachePolicy,
        toolChoice: request.toolChoice,
        structuredOutput: request.structuredOutput,
        cacheKey: request.cacheKey,
        transportHardTimeoutMillis: request.transportHardTimeoutMillis
    ))
}

// Request and attempt identifiers are transport bookkeeping, not model input.
// Retries get a fresh cancellable wire id and preserve every semantic field.
func modelRequestForAttempt(value: ModelRequest, attempt: Int64): ModelRequest {
    ModelRequest(
        value.model,
        value.messages,
        system: value.system,
        tools: value.tools,
        thinking: value.thinking,
        maxOutputTokens: value.maxOutputTokens,
        wireMaxOutputTokens: Some(value.wireMaxOutputTokens),
        resolvedPolicy: value.resolvedPolicy,
        streaming: value.streaming,
        parallelToolCalls: value.parallelToolCalls,
        requestId: if (attempt <= 1) {
            value.requestId
        } else {
            value.requestId + "-retry-" + (attempt - 1).toString()
        },
        serviceTier: value.serviceTier,
        cachePolicy: value.cachePolicy,
        toolChoice: value.toolChoice,
        structuredOutput: value.structuredOutput,
        cacheKey: value.cacheKey,
        transportHardTimeoutMillis: value.transportHardTimeoutMillis
    )
}

func attemptPolicyFor(
    request: ModelRequest,
    reason: AttemptPolicyReason,
    deadlines: ModelAttemptRecoveryPolicy
): AttemptPolicy {
    AttemptPolicy(
        request.model, request.thinking, request.toolChoice,
        request.maxOutputTokens, reason: reason,
        softDeadlineMillis: 0,
        hardDeadlineMillis: 0,
        streamIdleMillis: deadlines.streamIdleMillis,
        resolvedPolicy: request.resolvedPolicy
    )
}

func requestFromAttemptPolicy(request: ModelRequest, policy: AttemptPolicy): ModelRequest {
    ModelRequest(
        policy.model, request.messages, system: request.system, tools: request.tools,
        thinking: policy.thinking, maxOutputTokens: policy.maxOutputTokens,
        wireMaxOutputTokens: Some(policy.maxOutputTokens),
        resolvedPolicy: request.resolvedPolicy,
        streaming: request.streaming, parallelToolCalls: request.parallelToolCalls,
        requestId: request.requestId, serviceTier: request.serviceTier,
        cachePolicy: request.cachePolicy, toolChoice: policy.toolChoice,
        structuredOutput: request.structuredOutput, cacheKey: request.cacheKey,
        transportHardTimeoutMillis: 0
    )
}

func modelAttemptIdFor(
    semanticRequestId: SemanticModelRequestId,
    attempt: Int64
): ModelAttemptId {
    ModelAttemptId(semanticRequestId.value + "-attempt-" + attempt.toString())
}

class ModelAttemptFailurePlan {
    let disposition: AttemptRetryDisposition
    let outputLimited: Bool
    let willRetry: Bool

    init(
        disposition: AttemptRetryDisposition,
        outputLimited: Bool,
        willRetry: Bool
    ) {
        this.disposition = disposition
        this.outputLimited = outputLimited
        this.willRetry = willRetry
    }
}

// Keep replay safety next to retry classification so an error cannot acquire
// retry permission without satisfying the durable barrier rules.
func planModelAttemptFailure(
    error: AgentError,
    durableDecisionExists: Bool,
    replayBarrier: ModelAttemptReplayBarrier,
    attemptNo: Int64,
    maxAttempts: Int64,
    maxRecoveryRetries: Int64
): ModelAttemptFailurePlan {
    let disposition = retryDispositionForAttempt(error, durableDecisionExists)
    let outputLimited = match (error.attemptFailure) {
        case Some(failure) =>
            failure.kind == AttemptFailureKind.OutputLimitedBeforeDecision ||
                failure.kind == AttemptFailureKind.OutputLimited
        case None => false
    }
    // Malformed tool input is rejected before a durable decision exists, so it
    // can replay from the last canonical context after ToolEvidence.
    let malformedToolArguments = match (error.attemptFailure) {
        case Some(failure) => failure.kind == AttemptFailureKind.MalformedToolArguments
        case None => false
    }
    // A provider-terminal-missing result proves EOF preceded protocol terminal;
    // its bounded diagnostic permits replay after provisional evidence.
    let providerTerminalMissing = match (error.attemptFailure) {
        case Some(failure) => failure.kind == AttemptFailureKind.ProviderTerminalMissing
        case None => false
    }
    let replaySafe = replayBarrier == ModelAttemptReplayBarrier.NoBarrier ||
        (malformedToolArguments && replayBarrier == ModelAttemptReplayBarrier.ToolEvidence) ||
        (providerTerminalMissing &&
            (replayBarrier == ModelAttemptReplayBarrier.ToolEvidence ||
                replayBarrier == ModelAttemptReplayBarrier.ProviderTerminal)) ||
        (outputLimited &&
            (replayBarrier == ModelAttemptReplayBarrier.ToolEvidence ||
                replayBarrier == ModelAttemptReplayBarrier.ProviderTerminal))
    let retryableDisposition =
        disposition == AttemptRetryDisposition.RetryEscalated ||
        disposition == AttemptRetryDisposition.RetrySamePolicy
    ModelAttemptFailurePlan(
        disposition,
        outputLimited,
        retryableDisposition && attemptNo < maxAttempts &&
            maxRecoveryRetries > 0 && replaySafe
    )
}

