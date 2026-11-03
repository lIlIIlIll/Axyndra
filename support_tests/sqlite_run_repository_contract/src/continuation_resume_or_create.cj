package sqlite_run_repository_contract

import agent_domain.*
import agent_store.*
import persistence_runtime.*

// Actual same-transaction accounting/CAS contract. These rows are descriptive
// only; the actual user Source/document proof is exercised by Product tests.
func continuationResumeOrCreateFactsContract(root: String): Unit {
    let database = SqliteDatabase(root + "/continuation-resume-or-create.db")
    try {
        seedCanonicalRun(database)
        let runs = SqliteRunRepository(database)
        let repository = ContinuationAllowanceRepository(runs)
        let address = ContinuationAllowanceAddress(ThreadId("thread-1"), LaneId("main"), "installed-workflow", "goal")
        let source = modelPolicySha256Text("actual explicit resume proposal description")
        let write = { expected: ?ContinuationAllowanceFacts, control: ContinuationAllowanceControl =>
            database.transaction<Result<ContinuationAllowanceFacts>>({ tx =>
                repository.appendControlFacts(tx, address, expected, control, source, 10) }) }
        let read = { => database.transaction<Result<?ContinuationAllowanceFacts>>({ tx => repository.readFacts(tx, address) }) }
        expect(write(None, ContinuationAllowanceControl.Resume).isError(), "original Resume still rejects absent facts")
        expect(database.scalarInt("SELECT COUNT(*) FROM audit_events") == 0, "absent original Resume writes nothing")
        let created = write(None, ContinuationAllowanceControl.ResumeOrCreate("explicit-allowance", Some(1000))).value().getOrThrow()
        expect(created.enabled && !created.closed && created.tokenBudget.getOrThrow() == 1000 && created.tokensUsed == 0,
            "explicit typed absent operation creates the frozen budget rather than treating imported enabled data as authority")
        expect(write(None, ContinuationAllowanceControl.ResumeOrCreate("stale-absence", None)).isError(),
            "absence CAS cannot overwrite newly current facts")
        let paused = write(Some(created), ContinuationAllowanceControl.Pause).value().getOrThrow()
        let resumed = write(Some(paused), ContinuationAllowanceControl.ResumeOrCreate("must-not-replace", Some(9999))).value().getOrThrow()
        expect(resumed.enabled && resumed.allowanceId == created.allowanceId && resumed.tokenBudget.getOrThrow() == 1000 &&
            resumed.tokensUsed == paused.tokensUsed && resumed.generation == paused.generation + 1,
            "existing facts use original Resume, preserving identity, usage and established budget")
        let closed = write(Some(resumed), ContinuationAllowanceControl.Close).value().getOrThrow()
        let count = database.scalarInt("SELECT COUNT(*) FROM audit_events")
        expect(write(Some(closed), ContinuationAllowanceControl.ResumeOrCreate("must-not-reopen", Some(1000))).isError(),
            "explicit closed facts remain closed rather than being replaced by Create")
        expect(read().value().getOrThrow().getOrThrow().eventId == closed.eventId &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events") == count, "closed rejection does not change any facts")
        expect(database.scalarInt("SELECT COUNT(*) FROM operations") == 0 && database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0 && database.scalarInt("SELECT COUNT(*) FROM runs") == 1,
            "descriptive typed CAS cannot mint a Run, Tool admission, Receipt or model Attempt")
        println("Continuation explicit resume-or-create accounting contract passed: absent exact CAS, existing identity and budget, closed refusal; no authority")
    } finally { database.close() }
}
