package agent_product

import agent_domain.*
import agent_ports.*
import persistence_runtime.*
import std.collection.*

public class ProductStatsOverall {
    public let totalRequests: Int64
    public let successfulRequests: Int64
    public let failedRequests: Int64
    public let cancelledRequests: Int64
    public let errorRate: Float64
    public let cancellationRate: Float64
    public let totalInputTokens: Int64
    public let totalOutputTokens: Int64
    public let totalReasoningTokens: Int64
    public let totalCacheReadTokens: Int64
    public let totalCacheWriteTokens: Int64
    public let cacheRate: Float64
    public let totalCost: Float64
    public let totalCostMicros: ?Int64
    public let totalCostKnown: Bool
    public let totalPremiumRequests: Float64
    public let totalRuns: Int64
    public let totalTurns: Int64
    public let totalToolCalls: Int64
    public let firstTimestamp: Int64
    public let lastTimestamp: Int64

    public init(
        totalRequests: Int64,
        successfulRequests: Int64,
        failedRequests: Int64,
        cancelledRequests: Int64,
        totalInputTokens: Int64,
        totalOutputTokens: Int64,
        firstTimestamp: Int64,
        lastTimestamp: Int64,
        totalReasoningTokens!: Int64 = 0,
        totalCacheReadTokens!: Int64 = 0,
        totalCacheWriteTokens!: Int64 = 0,
        totalCostMicros!: ?Int64 = None,
        totalRuns!: Int64 = 0,
        totalTurns!: Int64 = 0,
        totalToolCalls!: Int64 = 0
    ) {
        this.totalRequests = totalRequests
        this.successfulRequests = successfulRequests
        this.failedRequests = failedRequests
        this.cancelledRequests = cancelledRequests
        this.errorRate = if (totalRequests == 0) {
            0.0
        } else {
            Float64(failedRequests) / Float64(totalRequests)
        }
        this.cancellationRate = if (totalRequests == 0) {
            0.0
        } else {
            Float64(cancelledRequests) / Float64(totalRequests)
        }
        this.totalInputTokens = totalInputTokens
        this.totalOutputTokens = totalOutputTokens
        this.totalReasoningTokens = totalReasoningTokens
        this.totalCacheReadTokens = totalCacheReadTokens
        this.totalCacheWriteTokens = totalCacheWriteTokens
        this.cacheRate = if (totalInputTokens == 0) {
            0.0
        } else {
            Float64(totalCacheReadTokens) / Float64(totalInputTokens)
        }
        this.totalCostMicros = totalCostMicros
        this.totalCostKnown = totalCostMicros.isSome()
        this.totalCost = match (totalCostMicros) {
            case Some(value) => Float64(value) / 1000000.0
            case None => 0.0
        }
        this.totalPremiumRequests = 0.0
        this.totalRuns = totalRuns
        this.totalTurns = totalTurns
        this.totalToolCalls = totalToolCalls
        this.firstTimestamp = firstTimestamp
        this.lastTimestamp = lastTimestamp
    }
}

// One durable run is the finest attribution boundary currently persisted by
// the product. `turns` records how many model/tool turns happened in that run.
public class ProductRunStats {
    // Agent runs map one-to-one to submitted turns; maintenance runs appear
    // only in byRun. The runtime-loop count remains `usage.totalTurns`.
    public let turnId: String
    public let runId: String
    public let sessionId: String
    public let model: String
    public let provider: String
    public let kind: String
    public let status: String
    public let archived: Bool
    public let timestamp: Int64
    public let usage: ProductStatsOverall

    public init(
        runId: String,
        sessionId: String,
        model: String,
        provider: String,
        kind: String,
        status: String,
        archived: Bool,
        timestamp: Int64,
        usage: ProductStatsOverall
    ) {
        this.turnId = runId
        this.runId = runId
        this.sessionId = sessionId
        this.model = model
        this.provider = provider
        this.kind = kind
        this.status = status
        this.archived = archived
        this.timestamp = timestamp
        this.usage = usage
    }
}

public class ProductSessionStats {
    public let sessionId: String
    public let model: String
    public let provider: String
    public let usage: ProductStatsOverall

    public init(
        sessionId: String,
        model: String,
        provider: String,
        usage: ProductStatsOverall
    ) {
        this.sessionId = sessionId
        this.model = model
        this.provider = provider
        this.usage = usage
    }
}

public class ProductProviderStats {
    public let provider: String
    public let sessions: Int64
    public let usage: ProductStatsOverall

    public init(
        provider: String,
        sessions: Int64,
        usage: ProductStatsOverall
    ) {
        this.provider = provider
        this.sessions = sessions
        this.usage = usage
    }
}

public class ProductDashboardStats {
    public let overall: ProductStatsOverall
    public let byTurn: Array<ProductRunStats>
    public let byRun: Array<ProductRunStats>
    public let bySession: Array<ProductSessionStats>
    public let byProvider: Array<ProductProviderStats>
    public let files: Int64

    public init(
        overall: ProductStatsOverall,
        files: Int64,
        byTurn!: Array<ProductRunStats> = [],
        byRun!: Array<ProductRunStats> = [],
        bySession!: Array<ProductSessionStats> = [],
        byProvider!: Array<ProductProviderStats> = []
    ) {
        this.overall = overall
        this.byTurn = byTurn
        this.byRun = byRun
        this.bySession = bySession
        this.byProvider = byProvider
        this.files = files
    }
}

class ProductStatsRuntime {
    private let runs: SqliteRunRepository
    private let sessionMetadata: SessionMetadataRepository
    private let providerProfiles: Array<ProviderProfile>
    private let modelCatalog: Array<ModelCatalogEntry>

    init(
        runs: SqliteRunRepository,
        sessionMetadata: SessionMetadataRepository,
        providerProfiles!: Array<ProviderProfile> = [],
        modelCatalog!: Array<ModelCatalogEntry> = []
    ) {
        this.runs = runs
        this.sessionMetadata = sessionMetadata
        this.providerProfiles = providerProfiles
        this.modelCatalog = modelCatalog
    }

    func snapshot(): Result<ProductDashboardStats> {
        try {
            let records = match (runs.records()) {
                case Result.Ok(values) => values
                case Result.Err(error) => return Result.Err(error)
            }

            let overall = StatsAccumulator()
            let runValues = ArrayList<ProductRunStats>()
            let turns = ArrayList<ProductRunStats>()
            let sessions = ArrayList<StatsSessionAccumulator>()
            let providers = ArrayList<StatsProviderAccumulator>()
            for (record in records) {
                let snapshot = record.snapshot
                let accounting = match (statsRunAccounting(
                    runs,
                    snapshot,
                    "sqlite:run/" + snapshot.runId.value
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) =>
                        return Result<ProductDashboardStats>.Err(error)
                }

                let attribution = match (statsRunAttribution(
                    accounting,
                    sessionMetadata,
                    snapshot.sessionId,
                    providerProfiles,
                    modelCatalog
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) =>
                        return Result<ProductDashboardStats>.Err(error)
                }
                let model = attribution.model
                let provider = attribution.provider
                let timestamp = record.startedAtMillis

                overall.add(snapshot, accounting, timestamp)
                let runUsage = StatsAccumulator()
                runUsage.add(snapshot, accounting, timestamp)
                let runStats = ProductRunStats(
                    snapshot.runId.value,
                    snapshot.sessionId.value,
                    model,
                    provider,
                    statsRunKindName(snapshot.kind),
                    statsStatusName(snapshot.status),
                    record.archived,
                    timestamp,
                    runUsage.freeze()
                )
                runValues.add(runStats)
                if (snapshot.kind == RunKind.Agent) { turns.add(runStats) }

                let session = match (findStatsSession(
                    sessions,
                    snapshot.sessionId.value
                )) {
                    case Some(value) =>
                        value.addAttribution(model, provider)
                        value
                    case None =>
                        let value = StatsSessionAccumulator(
                            snapshot.sessionId.value,
                            model,
                            provider
                        )
                        sessions.add(value)
                        value
                }
                session.usage.add(snapshot, accounting, timestamp)

                for (attempt in accounting.attempts) {
                    let attemptProvider = match (statsProviderForModel(
                        attempt.model,
                        providerProfiles,
                        modelCatalog
                    )) {
                        case Result.Ok(value) => value
                        case Result.Err(error) =>
                            return Result<ProductDashboardStats>.Err(error)
                    }
                    let providerStats = match (findStatsProvider(
                        providers,
                        attemptProvider
                    )) {
                        case Some(value) => value
                        case None =>
                            let value = StatsProviderAccumulator(attemptProvider)
                            providers.add(value)
                            value
                    }
                    providerStats.usage.addAttempt(attempt)
                    providerStats.addRun(
                        snapshot,
                        timestamp
                    )
                    providerStats.addSession(snapshot.sessionId.value)
                }
            }

            sortProductRunStats(runValues)
            sortProductRunStats(turns)
            sortStatsSessions(sessions)
            sortStatsProviders(providers)
            let sessionValues = ArrayList<ProductSessionStats>()
            for (value in sessions) {
                sessionValues.add(ProductSessionStats(
                    value.sessionId,
                    value.model,
                    value.provider,
                    value.usage.freeze()
                ))
            }
            let providerValues = ArrayList<ProductProviderStats>()
            for (value in providers) {
                providerValues.add(ProductProviderStats(
                    value.provider,
                    value.sessionIds.size,
                    value.usage.freeze()
                ))
            }
            Result.Ok(ProductDashboardStats(
                overall.freeze(),
                records.size,
                byTurn: turns.toArray(),
                byRun: runValues.toArray(),
                bySession: sessionValues.toArray(),
                byProvider: providerValues.toArray()
            ))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "stats.read_failed",
                error.message,
                fields: [ErrorField("source", "sqlite:runs")]
            ))
        }
    }
}

class StatsAccumulator {
    var requests: Int64 = 0
    var successfulRequests: Int64 = 0
    var failedRequests: Int64 = 0
    var cancelledRequests: Int64 = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var costMicros: Int64 = 0
    var costKnown = true
    var runs: Int64 = 0
    var turns: Int64 = 0
    var toolCalls: Int64 = 0
    var firstTimestamp: Int64 = 0
    var lastTimestamp: Int64 = 0

    func add(
        snapshot: RunSnapshot,
        accounting: StatsRunAccounting,
        timestamp: Int64
    ): Unit {
        for (attempt in accounting.attempts) {
            addAttempt(attempt)
        }
        addRunMetadata(snapshot, timestamp)
    }

    func addAttempt(attempt: ModelRequestAttempt): Unit {
        requests += 1
        match (attempt.outcome) {
            case ModelRequestOutcome.Succeeded =>
                successfulRequests += 1
                match (attempt.usage) {
                    case Some(usage) =>
                        inputTokens += usage.inputTokens
                        outputTokens += usage.outputTokens
                        reasoningTokens += usage.reasoningTokens
                        cacheReadTokens += usage.cacheReadTokens
                        cacheWriteTokens += usage.cacheWriteTokens
                        match (usage.costMicros) {
                            case Some(value) => costMicros += value
                            case None => costKnown = false
                        }
                    case None =>
                        // ModelRequestAttempt rejects this state. Keep the
                        // accumulator fail-closed if an invalid value ever
                        // reaches it through an alternate repository.
                        costKnown = false
                }
            case ModelRequestOutcome.Failed =>
                failedRequests += 1
                // No provider usage/cost was reported for this attempt; zero
                // must not be invented.
                costKnown = false
            case ModelRequestOutcome.Cancelled =>
                cancelledRequests += 1
                costKnown = false
        }
    }

    func addRunMetadata(snapshot: RunSnapshot, timestamp: Int64): Unit {
        runs += 1
        turns += snapshot.turns
        toolCalls += snapshot.toolCalls
        if (timestamp > 0) {
            if (firstTimestamp == 0 || timestamp < firstTimestamp) {
                firstTimestamp = timestamp
            }
            if (timestamp > lastTimestamp) {
                lastTimestamp = timestamp
            }
        }
    }

    func freeze(): ProductStatsOverall {
        ProductStatsOverall(
            requests,
            successfulRequests,
            failedRequests,
            cancelledRequests,
            inputTokens,
            outputTokens,
            firstTimestamp,
            lastTimestamp,
            totalReasoningTokens: reasoningTokens,
            totalCacheReadTokens: cacheReadTokens,
            totalCacheWriteTokens: cacheWriteTokens,
            totalCostMicros: if (requests > 0 && costKnown) {
                Some(costMicros)
            } else {
                None
            },
            totalRuns: runs,
            totalTurns: turns,
            totalToolCalls: toolCalls
        )
    }
}

class StatsSessionAccumulator {
    let sessionId: String
    var model: String
    var provider: String
    let usage = StatsAccumulator()

    init(sessionId: String, model: String, provider: String) {
        this.sessionId = sessionId
        this.model = model
        this.provider = provider
    }

    func addAttribution(model: String, provider: String): Unit {
        if (this.model != model) { this.model = "mixed" }
        if (this.provider != provider) { this.provider = "mixed" }
    }
}

class StatsRunAttribution {
    let model: String
    let provider: String

    init(model: String, provider: String) {
        this.model = model
        this.provider = provider
    }
}

class StatsProviderAccumulator {
    let provider: String
    let sessionIds = ArrayList<String>()
    let runIds = ArrayList<String>()
    let usage = StatsAccumulator()

    init(provider: String) { this.provider = provider }

    func addSession(sessionId: String): Unit {
        for (value in sessionIds where value == sessionId) { return }
        sessionIds.add(sessionId)
    }

    func addRun(snapshot: RunSnapshot, timestamp: Int64): Unit {
        for (value in runIds where value == snapshot.runId.value) { return }
        runIds.add(snapshot.runId.value)
        usage.addRunMetadata(snapshot, timestamp)
    }
}

class StatsRunAccounting {
    let attempts: Array<ModelRequestAttempt>

    init(attempts: Array<ModelRequestAttempt>) {
        this.attempts = attempts
    }
}

func statsRunAccounting(
    repository: RunRepository,
    snapshot: RunSnapshot,
    path: String
): Result<StatsRunAccounting> {
    let page = match (repository.events(snapshot.runId, 0)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(AgentError(
            AgentErrorKind.Internal,
            "stats.run_events_read_failed",
            error.message,
            fields: [ErrorField("path", path)]
        ))
    }
    let attempts = ArrayList<ModelRequestAttempt>()
    for (event in page.events) {
        match (event.payload) {
            case AgentEventPayload.ModelRequestAttemptCompleted(value) =>
                for (existing in attempts where
                    existing.requestId.value == value.requestId.value &&
                    existing.attempt == value.attempt) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Internal,
                        "stats.request_outcome_duplicate",
                        "durable model request attempt outcome is duplicated",
                        fields: [
                            ErrorField("path", path),
                            ErrorField("request_id", value.requestId.value),
                            ErrorField("attempt", value.attempt.toString())
                        ]
                    ))
                }
                attempts.add(value)
            case _ => ()
        }
    }
    if (attempts.size != snapshot.modelRequests) {
        return Result.Err(AgentError(
            AgentErrorKind.Internal,
            "stats.request_outcome_incomplete",
            "durable request outcomes do not match the run request count",
            fields: [
                ErrorField("path", path),
                ErrorField("snapshot_requests", snapshot.modelRequests.toString()),
                ErrorField("outcome_events", attempts.size.toString())
            ]
        ))
    }
    var input: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    for (attempt in attempts) {
        match (attempt.usage) {
            case Some(usage) =>
                input += usage.inputTokens
                output += usage.outputTokens
                reasoning += usage.reasoningTokens
                cacheRead += usage.cacheReadTokens
                cacheWrite += usage.cacheWriteTokens
            case None => ()
        }
    }
    if (input != snapshot.inputTokens || output != snapshot.outputTokens ||
        reasoning != snapshot.reasoningTokens ||
        cacheRead != snapshot.cacheReadTokens ||
        cacheWrite != snapshot.cacheWriteTokens) {
        return Result.Err(AgentError(
            AgentErrorKind.Internal,
            "stats.request_usage_mismatch",
            "durable request attempt usage does not match the run snapshot",
            fields: [ErrorField("path", path)]
        ))
    }
    Result.Ok(StatsRunAccounting(attempts.toArray()))
}

func statsSessionModel(
    repository: SessionMetadataRepository,
    sessionId: SessionId
): Result<String> {
    let model = match (repository.model(sessionId)) {
        case Result.Ok(value) => value.trimAscii()
        case Result.Err(error) => return Result.Err(error)
    }
    if (model == "") {
        return Result.Err(AgentError(
            AgentErrorKind.Internal,
            "stats.session_model_missing",
            "session model metadata is required for usage attribution",
            fields: [ErrorField("session_id", sessionId.value)]
        ))
    }
    Result.Ok(model)
}

func statsRunAttribution(
    accounting: StatsRunAccounting,
    sessionMetadata: SessionMetadataRepository,
    sessionId: SessionId,
    providerProfiles: Array<ProviderProfile>,
    modelCatalog: Array<ModelCatalogEntry>
): Result<StatsRunAttribution> {
    if (accounting.attempts.isEmpty()) {
        let model = match (statsSessionModel(sessionMetadata, sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return match (statsProviderForModel(
            model,
            providerProfiles,
            modelCatalog
        )) {
            case Result.Ok(provider) => Result.Ok(StatsRunAttribution(model, provider))
            case Result.Err(error) => Result.Err(error)
        }
    }
    var model = ""
    var provider = ""
    for (attempt in accounting.attempts) {
        let attemptProvider = match (statsProviderForModel(
            attempt.model,
            providerProfiles,
            modelCatalog
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (model == "") {
            model = attempt.model
        } else if (model != attempt.model) {
            model = "mixed"
        }
        if (provider == "") {
            provider = attemptProvider
        } else if (provider != attemptProvider) {
            provider = "mixed"
        }
    }
    Result.Ok(StatsRunAttribution(model, provider))
}

func statsProviderForModel(
    model: String,
    providerProfiles: Array<ProviderProfile>,
    modelCatalog: Array<ModelCatalogEntry>
): Result<String> {
    for (entry in modelCatalog where entry.displayId() == model) {
        for (profile in providerProfiles where
            profile.id == entry.providerProfile) {
            return Result.Ok(profile.provider)
        }
        return Result.Err(AgentError(
            AgentErrorKind.Internal,
            "stats.provider_profile_missing",
            "session model references an unavailable provider profile",
            fields: [
                ErrorField("model", model),
                ErrorField("provider_profile", entry.providerProfile)
            ]
        ))
    }
    match (model.indexOf("/")) {
        case Some(index) =>
            if (index == 0 || index + 1 >= model.size) {
                return Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "stats.session_model_invalid",
                    "session model metadata must be a model id or provider/model",
                    fields: [ErrorField("model", model)]
                ))
            }
            Result.Ok(model[..index])
        case None => Result.Ok(model)
    }
}

func findStatsSession(
    values: ArrayList<StatsSessionAccumulator>,
    sessionId: String
): ?StatsSessionAccumulator {
    for (value in values where value.sessionId == sessionId) {
        return Some(value)
    }
    None
}

func findStatsProvider(
    values: ArrayList<StatsProviderAccumulator>,
    provider: String
): ?StatsProviderAccumulator {
    for (value in values where value.provider == provider) {
        return Some(value)
    }
    None
}

func sortProductRunStats(values: ArrayList<ProductRunStats>): Unit {
    var index: Int64 = 1
    while (index < values.size) {
        var current = index
        while (current > 0 && statsProductRunLess(
            values[current],
            values[current - 1]
        )) {
            let previous = values[current - 1]
            values[current - 1] = values[current]
            values[current] = previous
            current--
        }
        index++
    }
}

func statsProductRunLess(left: ProductRunStats, right: ProductRunStats): Bool {
    if (left.runId != right.runId) { return left.runId < right.runId }
    if (left.sessionId != right.sessionId) {
        return left.sessionId < right.sessionId
    }
    if (left.archived != right.archived) { return left.archived }
    left.timestamp < right.timestamp
}

func sortStatsSessions(values: ArrayList<StatsSessionAccumulator>): Unit {
    var index: Int64 = 1
    while (index < values.size) {
        var current = index
        while (current > 0 &&
            values[current].sessionId < values[current - 1].sessionId) {
            let previous = values[current - 1]
            values[current - 1] = values[current]
            values[current] = previous
            current--
        }
        index++
    }
}

func sortStatsProviders(values: ArrayList<StatsProviderAccumulator>): Unit {
    var index: Int64 = 1
    while (index < values.size) {
        var current = index
        while (current > 0 &&
            values[current].provider < values[current - 1].provider) {
            let previous = values[current - 1]
            values[current - 1] = values[current]
            values[current] = previous
            current--
        }
        index++
    }
}

func statsStatusName(status: RunState): String {
    match (status) {
        case RunState.Created => "queued"
        case RunState.Running => "running"
        case RunState.WaitingApproval => "awaiting_approval"
        case RunState.WaitingExternal => "waiting_external"
        case RunState.Cancelling => "cancelling"
        case RunState.Cancelled => "cancelled"
        case RunState.Completed => "completed"
        case RunState.Failed => "failed"
        case RunState.RecoveryRequired => "recovery_required"
    }
}

func statsRunKindName(kind: RunKind): String {
    match (kind) {
        case RunKind.Agent => "agent"
        case RunKind.Maintenance => "maintenance"
    }
}
