package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PaidCanonicalThreadCursor113Tests {
    @TestCase
    func completeOriginalCorpusIsConsumedOutsideSqlLockAndLeavesNoLease113(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(45)
        try {
            let cursor = SqlitePaidCanonicalThreadCursor113(fixture.db, { bytes => fixture.pool.acquire(bytes) })
            let seen = OwnedReadbackVisitCapture()
            for (ordinal in 1..=fixture.count) {
                @Expect(cursor.withOrdinal(fixture.thread, 1, fixture.count + 1, ordinal,
                    { => Result<Unit>.Ok(()) }, { => Result<Unit>.Ok(()) }, { item, _ =>
                        // A different worker must really acquire the SAME DB
                        // lock. This would deadlock in original visit's TX callback.
                        let read: Future<Unit> = spawn {
                            @Expect(fixture.db.query("SELECT revision FROM threads WHERE id=?",
                                [SqlParameter.Text(fixture.thread.value)]).size, 1)
                        }
                        read.get(); seen.verify(item)
                    }).isOk(), true)
            }
            @Expect(seen.count, 45)
            @Expect(fixture.pool.usage()[0], 0); @Expect(fixture.pool.usage()[1], 0)
        } finally { fixture.close() }
    }
    @TestCase
    func actualRetainedAliasOutlivesCursorAndBorrowCannotAcknowledge113(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(2)
        try {
            let cursor = SqlitePaidCanonicalThreadCursor113(fixture.db, { bytes => fixture.pool.acquire(bytes) })
            let seen = OwnedReadbackVisitCapture()
            @Expect(cursor.withOrdinal(fixture.thread, 1, 3, 2, { => Result<Unit>.Ok(()) },
                { => Result<Unit>.Ok(()) }, { item, actual =>
                    @Expect(item.ordinal, 2)
                    @Expect(actual.closeAfterAliasRetirement().isError(), true)
                    match (actual.retainAliasCustody()) { case Result.Err(error) => Result<Unit>.Err(error)
                        case Result.Ok(alias) => seen.alias = Some(alias); Result<Unit>.Ok(()) }
                }).isOk(), true)
            @Expect(fixture.pool.usage()[0], 1); @Expect(fixture.pool.usage()[1] > 16777216, true)
            let alias = seen.alias.getOrThrow(); seen.alias = None<OwnedCanonicalThreadItemAliasCustody>
            @Expect(alias.withItem({ item => @Expect(item.ordinal, 2); Result<Unit>.Ok(()) }).isOk(), true)
            @Expect(alias.closeAfterAliasRetirement().isOk(), true)
            @Expect(fixture.pool.usage()[0], 0); @Expect(fixture.pool.usage()[1], 0)
        } finally { fixture.close() }
    }
    @TestCase
    func staleOrCancelledBoundaryDoesNotConsumeAndMidConsumerRevisionChangeRejects113(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(2)
        try {
            let cursor = SqlitePaidCanonicalThreadCursor113(fixture.db, { bytes => fixture.pool.acquire(bytes) })
            let seen = OwnedReadbackVisitCapture()
            var initiallyStale = false
            try { let _ = cursor.withOrdinal(fixture.thread, 2, 3, 2, { => Result<Unit>.Ok(()) },
                { => Result<Unit>.Ok(()) }, { _, _ => seen.count++; Result<Unit>.Ok(()) }) }
            catch (failure: OwnedCanonicalPaidFailure113) {
                let actual=failure.takeConsumer()
                @Expect(actual.withError({ error,_=>@Expect(error.kind,AgentErrorKind.RecoveryRequired) }).isOk(),true)
                @Expect(actual.acknowledgeAfterConsumption().isOk(),true);initiallyStale=true
            }
            @Expect(initiallyStale, true)
            @Expect(seen.count, 0)
            let cancelled: () -> Result<Unit> = { => Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                "fixture.cancelled", "original invocation cancelled")) }
            var rejected = false
            try { let _ = cursor.withOrdinal(fixture.thread, 1, 3, 2, cancelled,
                { => Result<Unit>.Ok(()) }, { _, _ => seen.count++; Result<Unit>.Ok(()) }) }
            catch (failure: OwnedCanonicalPaidFailure113) {
                let actual=failure.takeConsumer()
                @Expect(actual.withError({ error,_=>@Expect(error.kind,AgentErrorKind.Cancelled)
                    @Expect(error.code,"fixture.cancelled") }).isOk(),true)
                @Expect(actual.acknowledgeAfterConsumption().isOk(),true);rejected=true
            }
            @Expect(rejected, true); @Expect(seen.count, 0)
            var stale = false
            try { let _ = cursor.withOrdinal(fixture.thread, 1, 3, 2, { => Result<Unit>.Ok(()) },
                { => Result<Unit>.Ok(()) }, { _, _ =>
                    seen.count++
                    fixture.db.execute("UPDATE threads SET revision=2 WHERE id=?", [SqlParameter.Text(fixture.thread.value)])
                    Result<Unit>.Ok(()) }) }
            catch (failure: OwnedCanonicalPaidFailure113) {
                let actual=failure.takeConsumer()
                @Expect(actual.withError({ error,_=>@Expect(error.kind,AgentErrorKind.RecoveryRequired) }).isOk(),true)
                @Expect(actual.acknowledgeAfterConsumption().isOk(),true);stale=true
            }
            @Expect(stale, true); @Expect(seen.count, 1)
            @Expect(fixture.pool.usage()[0], 0); @Expect(fixture.pool.usage()[1], 0)
        } finally { fixture.close() }
    }
}
