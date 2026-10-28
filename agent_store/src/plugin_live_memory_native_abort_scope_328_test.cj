package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private class NativeAbortActualTestState328 {
    var effects:Int64=0
    var recovered:Int64=0
    var debt:?PluginLivePolicySettlementCleanupDebt326=None<PluginLivePolicySettlementCleanupDebt326>
    var witness:?SqliteLiveMemoryNativeAbortWitness324=None<SqliteLiveMemoryNativeAbortWitness324>
    var retired=false
}
private func nativeAbortActualFull328(tx:SqliteTransaction,state:NativeAbortActualTestState328):Unit{
    state.effects++
    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('partial',NULL,'fact','{}',1)", [])
    try{for(_ in 0..2){tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('partial',1,'retain','{}',1)", [])}}
    catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
}
private func nativeAbortActualSeed328(db:SqliteDatabase):Unit{
    // The committed real allocator seed remains outside the later autoabort.
    db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,'before',1,'retain','{}',1)",
        [SqlParameter.Int64Value(Int64.Max-1)])
}
// Actual SQLite resource/custody controls only. No Prepared, Source, approval,
// Known, reserved Receipt or parent oracle is fabricated by these controls.
@Test
class LiveMemoryActualNativeAbortResourceTests328 {
    @TestCase
    func ActualFullEndsOriginalTransactionAndFreshBeginRestoresAllRowsWithoutReplay():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/full.sqlite")
        let bank=LogicalJsonOwnerBudget();let owner=bank.acquire(65536);let state=NativeAbortActualTestState328()
        try{
            nativeAbortActualSeed328(db);db.execute("CREATE TABLE native_abort_control(mark TEXT NOT NULL)")
            db.withPaidLiveMemoryNativeAbortRecovery326(owner,65536,{tx=>nativeAbortActualFull328(tx,state)},{tx,witness=>
                state.recovered++
                witness.consume324(tx,owner,{original=>
                    @Expect(original.message.startsWith("SQLite step failed with code 13:"),true)
                    @Expect(tx.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
                    @Expect(tx.query("SELECT COUNT(*) FROM memories")[0].required(0),"0")
                    @Expect(tx.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),(Int64.Max-1).toString())
                    tx.execute("INSERT INTO native_abort_control(mark) VALUES('actual new transaction')", [])
                })
            })
            @Expect(state.effects,1);@Expect(state.recovered,1)
            @Expect(db.query("SELECT COUNT(*) FROM native_abort_control")[0].required(0),"1")
            @Expect(db.query("SELECT COUNT(*) FROM memories")[0].required(0),"0")
            @Expect(bank.usage()[0],1)
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func StillLiveConstraintTransactionCannotEnterNativeAutoabortRecovery():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/constraint.sqlite")
        let bank=LogicalJsonOwnerBudget();let owner=bank.acquire(65536);let state=NativeAbortActualTestState328()
        try{
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'before',1,'retain','{}',1)")
            try{db.withPaidLiveMemoryNativeAbortRecovery326(owner,65536,{tx=>
                state.effects++
                try{tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'duplicate',1,'retain','{}',1)", [])}
                catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
            },{_,_=>state.recovered++})}
            catch(error:LiveMemoryNativeAbortRetainedFailure326){
                @Expect(error.primary.message.startsWith("SQLite step failed with code 19:"),true)
                state.debt=Some(error.debt)
            }
            @Expect(state.effects,1);@Expect(state.recovered,0);@Expect(state.debt.isSome(),true)
            @Expect(state.debt.getOrThrow().closeAfterFailure().isOk(),true)
            @Expect(state.debt.getOrThrow().isAcknowledged(),true)
            state.debt=None<PluginLivePolicySettlementCleanupDebt326>
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
        }finally{state.debt=None<PluginLivePolicySettlementCleanupDebt326>;owner.close();db.close();remove(root,recursive:true)}
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func ActualRecoveryGuardFailureKeepsPaidDebtAndBlocksEveryDatabaseEntryUntilCheckedAck():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/guard.sqlite")
        let bank=LogicalJsonOwnerBudget();let owner=bank.acquire(65536);let state=NativeAbortActualTestState328()
        try{
            nativeAbortActualSeed328(db)
            try{db.withPaidLiveMemoryNativeAbortRecovery326(owner,65536,{tx=>nativeAbortActualFull328(tx,state)},{_,_=>
                state.recovered++
                throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.PermissionDenied,"actual.test_source_guard_denied","actual recovery callback refused reauthorization"))
            })}catch(error:LiveMemoryNativeAbortRetainedFailure326){
                @Expect(error.primary.message.startsWith("SQLite step failed with code 13:"),true)
                state.debt=Some(error.debt)
            }
            @Expect(state.effects,1);@Expect(state.recovered,1);@Expect(state.debt.isSome(),true)
            owner.close();@Expect(bank.usage()[0],1);@Expect(state.debt.getOrThrow().isAcknowledged(),false)
            var refused:Int64=0
            try{let _=db.query("SELECT COUNT(*) FROM memory_events")}catch(_:Exception){refused++}
            try{db.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('forbidden',NULL,'fact','{}',1)")}catch(_:Exception){refused++}
            try{db.transaction<Unit>({_=>()})}catch(_:Exception){refused++}
            try{db.readTransaction<Unit>({_=>()})}catch(_:Exception){refused++}
            try{db.close()}catch(_:Exception){refused++}
            @Expect(refused,5);@Expect(bank.usage()[0],1)
            @Expect(state.debt.getOrThrow().closeAfterFailure().isOk(),true)
            @Expect(state.debt.getOrThrow().isAcknowledged(),true)
            state.debt=None<PluginLivePolicySettlementCleanupDebt326>
            @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
            @Expect(db.query("SELECT COUNT(*) FROM memories")[0].required(0),"0")
        }finally{state.debt=None<PluginLivePolicySettlementCleanupDebt326>;owner.close();db.close();remove(root,recursive:true)}
    }
    @TestCase
    func ActualNativeAbortWitnessRejectsAnotherAllocationReplayAndRetiredTransaction():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/witness.sqlite")
        let bank=LogicalJsonOwnerBudget();let owner=bank.acquire(65536);let other=bank.acquire(65536)
        let state=NativeAbortActualTestState328()
        try{
            nativeAbortActualSeed328(db)
            db.withPaidLiveMemoryNativeAbortRecovery326(owner,65536,{tx=>nativeAbortActualFull328(tx,state)},{tx,witness=>
                state.witness=Some(witness)
                var wrong=false;var replay=false
                try{witness.consume324(tx,other,{_=>state.recovered+=100})}catch(_:Exception){wrong=true}
                @Expect(wrong,true);@Expect(state.recovered,0)
                witness.consume324(tx,owner,{_=>state.recovered++})
                try{witness.consume324(tx,owner,{_=>state.recovered+=100})}catch(_:Exception){replay=true}
                @Expect(replay,true);@Expect(state.recovered,1)
            })
            db.readTransaction<Unit>{tx=>
                try{state.witness.getOrThrow().consume324(tx,owner,{_=>state.recovered+=100})}
                catch(_:Exception){state.retired=true}}
            @Expect(state.retired,true);@Expect(state.effects,1);@Expect(state.recovered,1)
        }finally{state.witness=None<SqliteLiveMemoryNativeAbortWitness324>;other.close();owner.close();db.close();remove(root,recursive:true)}
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
}
