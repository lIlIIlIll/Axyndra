package sqlite_run_repository_contract

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.fs.*

// Real SQLite statistics/control-fact tests. The existing canonical-row fixture
// is not an authenticated user control or a Runtime continuation admission.
func continuationAllowanceFactsContract(root: String): Unit {
    let database = SqliteDatabase(root + "/continuation-allowance.db")
    try {
        seedCanonicalRun(database)
        let runs = SqliteRunRepository(database)
        let facts = ContinuationAllowanceRepository(runs)
        let address = ContinuationAllowanceAddress(ThreadId("thread-1"), LaneId("main"), "installed-workflow", "goal")
        let writeUsage = { input: Int64, output: Int64 =>
            expect(runs.save(RunSnapshot(RunId("run-1"), SessionId("thread-1"), RunState.Running,
                modelRequests: 1, inputTokens: input, outputTokens: output)).isOk(), "actual Run snapshot accounting persists")
        }
        let read = { => database.transaction<Result<?ContinuationAllowanceFacts>>({ tx => facts.readFacts(tx, address) }) }
        writeUsage(10, 5)
        let ordinary = runs.stats(SessionId("thread-1")).value().getOrThrow()
        let atomic = database.transaction<Result<SessionRunStats>>({ tx => runs.statsInTransaction(tx, SessionId("thread-1")) }).value().getOrThrow()
        expect(ordinary.inputTokens == atomic.inputTokens && ordinary.outputTokens == atomic.outputTokens &&
            ordinary.modelRequests == atomic.modelRequests && ordinary.costMicros == atomic.costMicros,
            "same-transaction statistics retain the original aggregation and known-cost semantics")
        let initial = allowanceContractControl(database, facts, address, None,
            ContinuationAllowanceControl.Create("allowance-1", Some(10))).value().getOrThrow()
        expect(initial.tokensUsed == 0 && initial.hasRemainingTokens(), "new facts anchor existing usage without charging previous work")
        writeUsage(14, 7)
        let accrued = read().value().getOrThrow().getOrThrow()
        expect(accrued.tokensUsed == 6 && accrued.revision == initial.revision,
            "read-only refresh derives six tokens without appending a second usage ledger")
        let paused = allowanceContractControl(database, facts, address, Some(initial), ContinuationAllowanceControl.Pause).value().getOrThrow()
        expect(paused.tokensUsed == 6 && !paused.hasRemainingTokens() && paused.generation > initial.generation,
            "pause records observed active usage and invalidates old-generation descriptions")
        writeUsage(70, 30)
        expect(read().value().getOrThrow().getOrThrow().tokensUsed == 6, "paused interval usage is excluded as in the original Goal gate")
        let resumed = allowanceContractControl(database, facts, address, Some(paused), ContinuationAllowanceControl.Resume).value().getOrThrow()
        expect(resumed.tokensUsed == 6 && resumed.observedTotalTokens == 100,
            "resume freezes the new real baseline without refunding previously used tokens")
        writeUsage(72, 32)
        let exhausted = read().value().getOrThrow().getOrThrow()
        expect(exhausted.tokensUsed == 10 && !exhausted.hasRemainingTokens(), "exact total budget forbids another Run suggestion")
        let increased = allowanceContractControl(database, facts, address, Some(resumed), ContinuationAllowanceControl.SetBudget(Some(20))).value().getOrThrow()
        expect(increased.tokensUsed == 10 && increased.hasRemainingTokens(), "explicit host control data changes the limit without resetting use")
        expect(allowanceContractControl(database, facts, address, Some(initial), ContinuationAllowanceControl.Resume).isError(),
            "stale exact event identity cannot overwrite current control facts")
        expect(allowanceContractControl(database, facts, address, Some(increased), ContinuationAllowanceControl.SetBudget(Some(0))).isError(),
            "zero or negative token limits cannot become unbounded")
        let eventsBefore = database.scalarInt("SELECT COUNT(*) FROM audit_events")
        var rolledBack = false
        try {
            database.transaction<Unit>({ tx =>
                expect(facts.appendControlFacts(tx, address, Some(increased), ContinuationAllowanceControl.Pause,
                    modelPolicySha256Text("test-only-control-description"), 20).isOk(), "control fact write occurs in the caller transaction")
                tx.execute("INSERT INTO deliberately_missing_allowance_contract_table(value) VALUES (1)")
            })
        } catch (_: Exception) { rolledBack = true }
        expect(rolledBack && database.scalarInt("SELECT COUNT(*) FROM audit_events") == eventsBefore &&
            read().value().getOrThrow().getOrThrow().eventId == increased.eventId,
            "later document-side failure rolls back the accounting control in the same real SQLite transaction")
        let restarted = allowanceContractControl(database, facts, address, Some(increased), ContinuationAllowanceControl.RestartPause).value().getOrThrow()
        let reopened = SqliteDatabase(root + "/continuation-allowance.db")
        try {
            let restored = ContinuationAllowanceRepository(SqliteRunRepository(reopened))
            let historical = reopened.transaction<Result<?ContinuationAllowanceFacts>>({ tx => restored.readFacts(tx, address) }).value().getOrThrow().getOrThrow()
            expect(!historical.enabled && historical.tokensUsed == 10 && historical.generation == restarted.generation,
                "reopened host facts retain restart pause and never reconstruct a Runtime seal")
        } finally { reopened.close() }
        writeUsage(1, 1)
        expect(read().isError(), "statistics regression is recovery debt rather than newly available budget")
        writeUsage(72, 32)
        let closed = allowanceContractControl(database, facts, address, Some(restarted), ContinuationAllowanceControl.Close).value().getOrThrow()
        expect(allowanceContractControl(database, facts, address, Some(closed), ContinuationAllowanceControl.Resume).isError(),
            "closed work cannot be resumed by changing document status")
        let original = database.query("SELECT payload FROM audit_events WHERE id=?", [SqlParameter.Int64Value(closed.eventId)])[0].required(0)
        database.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text("not-a-canonical-value"), SqlParameter.Int64Value(closed.eventId)])
        expect(read().isError(), "corrupt host evidence is never treated as a missing grant or empty use")
        database.execute("UPDATE audit_events SET payload=? WHERE id=?", [SqlParameter.Text(original), SqlParameter.Int64Value(closed.eventId)])
        expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 && database.scalarInt("SELECT COUNT(*) FROM operations") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM runs") == 1,
            "accounting descriptions create no new Run, Attempt, Tool operation or execution authority")
        println("Continuation allowance accounting contract passed: same statistics, interval accounting, exact CAS, rollback, restart pause and corrupt/regressed refusal; no Run admission")
    } finally { database.close() }
}

func allowanceContractControl(database: SqliteDatabase, facts: ContinuationAllowanceRepository,
    address: ContinuationAllowanceAddress, expected: ?ContinuationAllowanceFacts,
    control: ContinuationAllowanceControl): Result<ContinuationAllowanceFacts> {
    database.transaction<Result<ContinuationAllowanceFacts>>({ tx => facts.appendControlFacts(tx, address, expected,
        control, modelPolicySha256Text("test-only-control-description"), 10) })
}
