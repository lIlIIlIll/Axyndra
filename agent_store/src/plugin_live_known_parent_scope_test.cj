package agent_store

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

// Real disk Runtime negatives/default compatibility ONLY. The existing
// WaitingFailureFixture creates/attests an actual ordinary Direct read, not a
// live Parent. No successful neutral witness/Source/ACK is fabricated here.
func liveKnownFixtureDebtAccepts(f:WaitingFailureFixture,pool:LogicalJsonOwnerBudget):Bool{
    try{f.database.readTransaction<Unit>{tx=>requirePluginLiveKnownRunOperationDebt(tx,f.thread,f.run,
        {bytes=>pool.acquire(max(bytes,16777216))},{=>Result<Unit>.Ok(())})};true}
    catch(_:Exception){false}
}

@Test
class PluginLiveKnownParentScopeTests{
    @TestCase
    func defaultCanonicalKnownFailureKeepsReceiptAndToolResultWithoutNeutralMarker():Unit{
        let f=WaitingFailureFixture();let pool=LogicalJsonOwnerBudget()
        try{
            let resolution=f.terminal()
            @Expect(waitingFailureCommitted(f.commit(resolution)),true)
            @Expect(f.database.scalarInt("SELECT count(*) FROM operation_receipts WHERE operation_id="+sqliteText(f.operation.value)),1)
            @Expect(f.database.scalarInt("SELECT count(*) FROM items WHERE id="+sqliteText(f.resultItem.value)),1)
            @Expect(f.database.scalarInt("SELECT count(*) FROM audit_events WHERE kind='plugin_live_known_parent_canonical_v1'"),0)
            @Expect(liveKnownFixtureDebtAccepts(f,pool),true)
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{f.close()}
    }
    @TestCase
    func preparedAndUnknownActualOperationRemainDebtWithoutChangingOriginalOwners():Unit{
        let f=WaitingFailureFixture(waiting:false);let pool=LogicalJsonOwnerBudget()
        try{
            @Expect(liveKnownFixtureDebtAccepts(f,pool),false)
            @Expect(f.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            // Explicit corruption injection is negative data, not a grant.
            f.database.execute("UPDATE operations SET state='recovery_required' WHERE id=?",[SqlParameter.Text(f.operation.value)])
            @Expect(liveKnownFixtureDebtAccepts(f,pool),false)
            @Expect(f.database.scalarInt("SELECT count(*) FROM items WHERE id="+sqliteText(f.resultItem.value)),0)
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{f.close()}
    }
    @TestCase
    func ordinaryOperationCannotDischargeByAStoredPrivateKindOrDuplicateMarker():Unit{
        let f=WaitingFailureFixture(waiting:false);let pool=LogicalJsonOwnerBudget()
        try{
            for(_ in 0..2){
                f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_known_parent_canonical_v1','n',1)",
                    [SqlParameter.Text(f.thread.value),SqlParameter.Text(f.run.value),SqlParameter.Text(f.operation.value)])
                @Expect(liveKnownFixtureDebtAccepts(f,pool),false)
                @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
                @Expect(f.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            }
            @Expect(f.database.scalarInt("SELECT count(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func cancellationReleasesOnlyTheNewPhaseAndKeepsActualPendingRuntimeDebt():Unit{
        let f=WaitingFailureFixture(waiting:false);let pool=LogicalJsonOwnerBudget()
        let held=pool.acquire(8388608)
        try{
            var denied=false
            try{f.database.readTransaction<Unit>{tx=>requirePluginLiveKnownRunOperationDebt(tx,f.thread,f.run,
                {bytes=>pool.acquire(max(bytes,16777216))},{=>Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                    "fixture.known_phase_cancelled","actual cancellation"))})}}
            catch(_:Exception){denied=true}
            @Expect(denied,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],67108864)
            @Expect(f.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            @Expect(f.database.scalarInt("SELECT count(*) FROM audit_events WHERE kind='plugin_live_known_parent_canonical_v1'"),0)
        }finally{held.close();f.close()}
    }
}
