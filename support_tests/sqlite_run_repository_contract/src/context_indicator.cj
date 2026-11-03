package sqlite_run_repository_contract

import agent_domain.*
import agent_store.*
import persistence_runtime.*

func contextIndicatorSnapshot(database: SqliteDatabase, repository: SqliteRunRepository,
    id: String, ordinal: Int64, kind: RunKind, input: Int64, output: Int64, requests: Int64): Unit {
    database.execute("INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
        "VALUES(?,'thread-1','turn-1',?,'completed','{}','{}','{}','{}',?)",
        [SqlParameter.Text(id), SqlParameter.Int64Value(ordinal), SqlParameter.Int64Value(ordinal)])
    expect(repository.save(RunSnapshot(RunId(id), SessionId("thread-1"), RunState.Completed, kind: kind,
        modelRequests: requests, inputTokens: input, outputTokens: output, lastInputTokens: input,
        lastOutputTokens: output, lastRequestDurationMillis: if (kind == RunKind.Chat) { 0 } else { 99 },
        costMicros: Some(input + output))).isOk(), "typed Run context fixture persists")
}

func maintenanceContextIndicatorContract(root: String): Unit {
    let path = root + "/context-indicators.db"
    let database = SqliteDatabase(path)
    try {
        seedCanonicalRun(database)
        let repository = SqliteRunRepository(database)
        let session = SessionId("thread-1")
        expect(repository.save(RunSnapshot(RunId("run-1"), session, RunState.Completed,
            modelRequests: 1, inputTokens: 240000, outputTokens: 100, costMicros: Some(1000),
            lastInputTokens: 240000, lastOutputTokens: 100, lastRequestDurationMillis: 1000)).isOk(),
            "user provider usage is durable before maintenance")
        contextIndicatorSnapshot(database, repository, "maintenance", 2, RunKind.Maintenance, 11, 1, 1)
        contextIndicatorSnapshot(database, repository, "compaction", 3, RunKind.Compaction, 0, 0, 1)
        contextIndicatorSnapshot(database, repository, "navigation", 4, RunKind.NavigationSummary, 12, 1, 1)
        contextIndicatorSnapshot(database, repository, "verification", 5, RunKind.Verification, 13, 1, 1)
        let totals = repository.stats(session).value().getOrThrow()
        expect(totals.runs == 5 && totals.modelRequests == 5 && totals.inputTokens == 240036 &&
            totals.outputTokens == 103 && totals.costMicros == Some(1039),
            "all maintenance requests, tokens and costs remain in original totals")
        expect(totals.lastInputTokens == 240000 && totals.lastOutputTokens == 100 && totals.lastRequestDurationMillis == 1000,
            "maintenance and zero-usage compaction cannot replace the user context indicator")
        contextIndicatorSnapshot(database, repository, "chat", 6, RunKind.Chat, 42, 2, 1)
        contextIndicatorSnapshot(database, repository, "local-only", 7, RunKind.Agent, 0, 0, 0)
        // A newer request-less snapshot cannot select a bogus last-input value.
        expect(repository.save(RunSnapshot(RunId("local-only"), session, RunState.Failed,
            lastInputTokens: 999, lastOutputTokens: 999, lastRequestDurationMillis: 999)).isOk(), "local-only snapshot persists")
    } finally { database.close() }
    let reopened = SqliteDatabase(path)
    try {
        let repository = SqliteRunRepository(reopened)
        let totals = repository.stats(SessionId("thread-1")).value().getOrThrow()
        expect(repository.find(RunId("compaction")).value().getOrThrow().kind == RunKind.Compaction,
            "maintenance kind survives codec and SQLite reopen")
        expect(totals.runs == 7 && totals.modelRequests == 6 && totals.inputTokens == 240078 &&
            totals.outputTokens == 105 && totals.costMicros == Some(1083), "reopened totals include all maintenance")
        expect(totals.lastInputTokens == 42 && totals.lastOutputTokens == 2 && totals.lastRequestDurationMillis == 0,
            "latest real Chat request wins even with zero millisecond duration; local-only Run is ignored")
        println("Maintenance context indicator contract passed: original totals, typed user context and actual reopen")
    } finally { reopened.close() }
}
