package stats_contract

import agent_domain.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        let state = root + "/state"
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: state,
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let session = product.applicationSession()
        let database = SqliteDatabase(state + "/state.db")

        // Two successful logical requests in one Agent turn.
        writeRun(
            database,
            "z-run",
            "session-b",
            "zeta/gpt",
            RunState.Completed,
            2,
            120,
            35,
            reasoningTokens: 12,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            costMicros: Some(150),
            turns: 2,
            toolCalls: 3
        )
        writeRun(
            database,
            "m-run",
            "session-b",
            "zeta/gpt",
            RunState.Completed,
            1,
            10,
            5,
            costMicros: Some(50),
            turns: 1,
            toolCalls: 1
        )
        // Three failed retry attempts must be three failures, not one failure
        // plus two fabricated successes.
        writeRun(
            database,
            "a-run",
            "session-a",
            "alpha/claude",
            RunState.Failed,
            3,
            0,
            0,
            archived: true,
            turns: 4,
            toolCalls: 2,
            outcomes: [
                ModelRequestOutcome.Failed,
                ModelRequestOutcome.Failed,
                ModelRequestOutcome.Failed
            ]
        )
        // One retry failure followed by one success remains 1/1.
        writeRun(
            database,
            "r-run",
            "session-a",
            "maintenance/summarizer",
            RunState.Completed,
            2,
            5,
            2,
            costMicros: Some(25),
            turns: 1,
            kind: RunKind.Maintenance,
            outcomes: [
                ModelRequestOutcome.Failed,
                ModelRequestOutcome.Succeeded
            ]
        )
        writeRun(
            database,
            "c-run",
            "session-a",
            "alpha/claude",
            RunState.Cancelled,
            1,
            0,
            0,
            turns: 1,
            outcomes: [ModelRequestOutcome.Cancelled]
        )

        let snapshot = session.dashboardStats().value().getOrThrow()
        let overall = snapshot.overall
        expect(snapshot.files == 5, "counts active and archived durable run snapshots")
        expect(
            overall.totalRequests == 9 &&
            overall.successfulRequests == 4 &&
            overall.failedRequests == 4 &&
            overall.cancelledRequests == 1,
            "counts every provider attempt outcome without inferring success from run status"
        )
        expect(
            snapshot.byRun[0].runId == "a-run" &&
            snapshot.byRun[0].usage.totalRequests == 3 &&
            snapshot.byRun[0].usage.successfulRequests == 0 &&
            snapshot.byRun[0].usage.failedRequests == 3 &&
            snapshot.byRun[1].runId == "c-run" &&
            snapshot.byRun[1].usage.cancelledRequests == 1 &&
            snapshot.byRun[3].runId == "r-run" &&
            snapshot.byRun[3].kind == "maintenance" &&
            snapshot.byRun[3].model == "maintenance/summarizer" &&
            snapshot.byRun[3].provider == "maintenance" &&
            snapshot.byRun[3].usage.successfulRequests == 1 &&
            snapshot.byRun[3].usage.failedRequests == 1,
            "all-failed, fail-then-success, and cancellation remain distinct"
        )
        expect(
            overall.totalInputTokens == 135 &&
            overall.totalOutputTokens == 42 &&
            overall.totalReasoningTokens == 12 &&
            overall.totalCacheReadTokens == 30 &&
            overall.totalCacheWriteTokens == 10,
            "aggregates usage only from successful attempts"
        )
        expect(
            overall.totalRuns == 5 && overall.totalTurns == 9 &&
            overall.totalToolCalls == 6 && overall.firstTimestamp > 0 &&
            overall.lastTimestamp >= overall.firstTimestamp,
            "preserves run, runtime-turn, tool, and timestamp totals"
        )
        expect(
            !overall.totalCostKnown && overall.totalCostMicros.isNone() &&
            overall.totalCost == 0.0,
            "failed or cancelled requests without provider cost keep aggregate cost unknown"
        )
        expect(
            snapshot.byTurn.size == 4 &&
            snapshot.byTurn[0].turnId == "a-run" &&
            snapshot.byTurn[3].turnId == "z-run" &&
            snapshot.byRun.size == 5,
            "maintenance runs remain visible without being mislabeled as user turns"
        )
        expect(
            snapshot.bySession.size == 2 &&
            snapshot.bySession[0].sessionId == "session-a" &&
            snapshot.bySession[0].model == "mixed" &&
            snapshot.bySession[0].provider == "mixed" &&
            snapshot.bySession[0].usage.successfulRequests == 1 &&
            snapshot.bySession[0].usage.failedRequests == 4 &&
            snapshot.bySession[0].usage.cancelledRequests == 1 &&
            snapshot.bySession[1].sessionId == "session-b" &&
            snapshot.bySession[1].usage.successfulRequests == 3 &&
            snapshot.bySession[1].usage.totalCostMicros == Some(200),
            "session groups aggregate explicit attempt outcomes"
        )
        expect(
            snapshot.byProvider.size == 3 &&
            snapshot.byProvider[0].provider == "alpha" &&
            snapshot.byProvider[0].usage.successfulRequests == 0 &&
            snapshot.byProvider[0].usage.failedRequests == 3 &&
            snapshot.byProvider[0].usage.cancelledRequests == 1 &&
            snapshot.byProvider[0].usage.totalCostMicros.isNone() &&
            snapshot.byProvider[1].provider == "maintenance" &&
            snapshot.byProvider[1].usage.successfulRequests == 1 &&
            snapshot.byProvider[1].usage.failedRequests == 1 &&
            snapshot.byProvider[1].usage.totalCostMicros.isNone() &&
            snapshot.byProvider[2].provider == "zeta" &&
            snapshot.byProvider[2].usage.successfulRequests == 3 &&
            snapshot.byProvider[2].usage.totalCostMicros == Some(200),
            "provider groups use the model recorded on each request attempt"
        )

        // Replace every unknown attempt with successful, priced requests.
        writeRun(
            database,
            "a-run",
            "session-a",
            "alpha/claude",
            RunState.Completed,
            3,
            80,
            20,
            archived: true,
            reasoningTokens: 3,
            cacheReadTokens: 20,
            cacheWriteTokens: 5,
            costMicros: Some(75),
            turns: 4,
            toolCalls: 2
        )
        writeRun(
            database,
            "r-run",
            "session-a",
            "alpha/claude",
            RunState.Completed,
            2,
            5,
            2,
            costMicros: Some(25),
            turns: 1
        )
        writeRun(
            database,
            "c-run",
            "session-a",
            "alpha/claude",
            RunState.Completed,
            1,
            1,
            1,
            costMicros: Some(10),
            turns: 1
        )
        let known = session.dashboardStats().value().getOrThrow()
        expect(
            known.overall.successfulRequests == 9 &&
            known.overall.failedRequests == 0 &&
            known.overall.cancelledRequests == 0 &&
            known.overall.totalCostKnown &&
            known.overall.totalCostMicros == Some(310) &&
            known.byProvider[0].usage.totalCostMicros == Some(110),
            "all explicit successful prices produce exact grouped costs"
        )

        database.execute("UPDATE runs SET app_snapshot='{not-json' WHERE id='a-run'")
        expect(
            session.dashboardStats().isError(),
            "rejects corrupt current-format durable snapshots"
        )
        writeRun(
            database, "a-run", "session-a", "alpha/claude", RunState.Completed,
            3, 80, 20, reasoningTokens: 3, cacheReadTokens: 20,
            cacheWriteTokens: 5, costMicros: Some(75), turns: 4, toolCalls: 2
        )

        let missingRun = RunId("missing-model")
        let missingSession = SessionId("missing-model-session")
        ensureStatsRun(database, missingRun.value, missingSession.value, false)
        let missingRepository = SqliteRunRepository(database)
        missingRepository.save(RunSnapshot(
            missingRun,
            missingSession,
            RunState.Completed,
            sequence: 1,
            modelRequests: 1,
            inputTokens: 1,
            outputTokens: 1,
            costMicros: Some(1)
        )).value().getOrThrow()
        missingRepository.append(attemptEvent(
            missingRun,
            "fixture",
            "missing-model-request",
            1,
            1,
            ModelRequestOutcome.Succeeded,
            usage: Some(ModelUsage(
                inputTokens: 1,
                outputTokens: 1,
                costMicros: Some(1)
            ))
        )).value().getOrThrow()
        let selfAttributed = session.dashboardStats().value().getOrThrow()
        var missingAttributed = false
        for (value in selfAttributed.byRun where value.runId == missingRun.value) {
            missingAttributed = value.model == "fixture" && value.provider == "fixture"
        }
        expect(
            missingAttributed,
            "request attempt metadata attributes a run without mutable session model metadata"
        )

        database.close()
        println("stats contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func writeRun(
    database: SqliteDatabase,
    runId: String,
    sessionId: String,
    model: String,
    status: RunState,
    requests: Int64,
    inputTokens: Int64,
    outputTokens: Int64,
    archived!: Bool = false,
    reasoningTokens!: Int64 = 0,
    cacheReadTokens!: Int64 = 0,
    cacheWriteTokens!: Int64 = 0,
    costMicros!: ?Int64 = None,
    turns!: Int64 = 0,
    toolCalls!: Int64 = 0,
    kind!: RunKind = RunKind.Agent,
    outcomes!: Array<ModelRequestOutcome> = []
): Unit {
    let resolvedOutcomes = if (outcomes.isEmpty()) {
        let values = ArrayList<ModelRequestOutcome>()
        for (_ in 0..requests) {
            values.add(if (status == RunState.Completed) {
                ModelRequestOutcome.Succeeded
            } else if (status == RunState.Cancelled) {
                ModelRequestOutcome.Cancelled
            } else {
                ModelRequestOutcome.Failed
            })
        }
        values.toArray()
    } else {
        outcomes
    }
    if (resolvedOutcomes.size != requests) {
        throw IllegalArgumentException("fixture outcomes must match requests")
    }
    var lastSuccess: Int64 = -1
    for (index in 0..resolvedOutcomes.size) {
        if (resolvedOutcomes[index] == ModelRequestOutcome.Succeeded) {
            lastSuccess = index
        }
    }
    if (lastSuccess < 0 && (inputTokens != 0 || outputTokens != 0 ||
        reasoningTokens != 0 || cacheReadTokens != 0 || cacheWriteTokens != 0)) {
        throw IllegalArgumentException("failed-only fixture cannot report successful usage")
    }

    ensureStatsRun(database, runId, sessionId, archived)
    SqliteSessionMetadataRepository(database)
        .setModel(SessionId(sessionId), model)
        .value().getOrThrow()
    let repository = SqliteRunRepository(database)
    database.execute("DELETE FROM app_run_events WHERE run_id=" + sqliteText(runId))
    database.execute("DELETE FROM app_run_event_heads WHERE run_id=" + sqliteText(runId))
    repository.save(RunSnapshot(
        RunId(runId),
        SessionId(sessionId),
        status,
        sequence: requests,
        modelRequests: requests,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        costMicros: costMicros,
        turns: turns,
        toolCalls: toolCalls,
        kind: kind
    )).value().getOrThrow()

    for (index in 0..resolvedOutcomes.size) {
        let outcome = resolvedOutcomes[index]
        let sequence = index + 1
        let explicitRetry = !outcomes.isEmpty()
        let requestId = if (explicitRetry) {
            runId + "-request"
        } else {
            runId + "-request-" + sequence.toString()
        }
        let attempt = if (explicitRetry) { sequence } else { 1 }
        let usage: ?ModelUsage = if (outcome == ModelRequestOutcome.Succeeded) {
            if (index == lastSuccess) {
                Some(ModelUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    reasoningTokens: reasoningTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    costMicros: costMicros
                ))
            } else {
                Some(ModelUsage(costMicros: match (costMicros) {
                    case Some(_) => Some(0)
                    case None => None
                }))
            }
        } else {
            None
        }
        repository.append(attemptEvent(
            RunId(runId),
            model,
            requestId,
            attempt,
            sequence,
            outcome,
            usage: usage
        )).value().getOrThrow()
    }
}

func ensureStatsRun(
    database: SqliteDatabase,
    runId: String,
    sessionId: String,
    archived: Bool
): Unit {
    let status = if (archived) { "closed" } else { "open" }
    if (database.scalarInt(
        "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId)
    ) == 0) {
        database.execute(
            "INSERT INTO threads VALUES(" + sqliteText(sessionId) + ",0,'workspace'," +
                sqliteText(status) + ",1,NULL)"
        )
    }
    if (database.scalarInt(
        "SELECT COUNT(*) FROM runs WHERE id=" + sqliteText(runId)
    ) != 0) { return }
    let turnId = runId + "-turn"
    let ordinal = database.scalarInt(
        "SELECT COUNT(*) FROM turns WHERE thread_id=" + sqliteText(sessionId)
    ) + 1
    database.execute(
        "INSERT INTO turns VALUES(" + sqliteText(turnId) + "," + sqliteText(sessionId) + "," +
            ordinal.toString() + ",'completed','fixture-user',NULL)"
    )
    database.execute(
        "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
            "started_at_millis,finished_at_millis,cancellation_reason) VALUES(" +
            sqliteText(runId) + "," + sqliteText(sessionId) + "," + sqliteText(turnId) +
            ",1,'completed','{}','{}','{}','{}'," + ordinal.toString() + "," +
            ordinal.toString() + ",NULL)"
    )
}

func attemptEvent(
    runId: RunId,
    model: String,
    requestId: String,
    attempt: Int64,
    sequence: Int64,
    outcome: ModelRequestOutcome,
    usage!: ?ModelUsage = None
): AgentEvent {
    let id = RequestId(requestId)
    AgentEvent(
        EventMeta(
            sequence,
            TraceId("stats-" + runId.value),
            runId,
            occurredAtMillis: sequence,
            requestId: Some(id)
        ),
        AgentEventPayload.ModelRequestAttemptCompleted(
            ModelRequestAttempt(
                id,
                model,
                attempt,
                outcome,
                usage: usage,
                errorCode: match (outcome) {
                    case ModelRequestOutcome.Succeeded => ""
                    case ModelRequestOutcome.Failed => "fixture.failed"
                    case ModelRequestOutcome.Cancelled => "run.cancelled"
                }
            )
        )
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
