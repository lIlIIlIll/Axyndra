package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private class LiveMemoryRollbackTestState317 {
    var acknowledged=false
    var original=""
    var debt=false
    var action=false
    var refused=false
    var calls:Int64=0
    var stale:?SqliteTransaction=None<SqliteTransaction>
}

// Physical SQLite resource controls only. These do not pretend to execute
// an Operation/Source/approval/Root or create a Known failure Receipt.
@Test
class LiveMemoryActualRollbackScopeTests317 {
    @TestCase
    func ActualConstraintRollbackRestoresWholeRowsAndAllocatorInSameWriteTransaction():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/rollback.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'before',1,'retain','{}',1)")
            let state=LiveMemoryRollbackTestState317()
            db.withLiveMemoryRollbackTransaction317(owner,65536,{tx=>
                tx.withCheckedLiveMemoryRollback317(owner,65536,{=>
                    tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('partial',1,'retain','{}',1)", [])
                    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('partial',NULL,'fact','{}',1)", [])
                    try{tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'duplicate',1,'retain','{}',1)", [])}
                    catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
                },{actual=>
                    @Expect(actual.message.startsWith("SQLite step failed with code 19:"),true)
                    @Expect(tx.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
                    @Expect(tx.query("SELECT COUNT(*) FROM memories")[0].required(0),"0")
                    @Expect(tx.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),"1")
                    state.acknowledged=true
                })
            })
            @Expect(state.acknowledged,true)
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func ActualSqliteFullCanNeverAcknowledgeAnEndedOrUnrestoredTransaction():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/full.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,'before',1,'retain','{}',1)",[SqlParameter.Int64Value(Int64.Max-1)])
            let state=LiveMemoryRollbackTestState317()
            try{db.withLiveMemoryRollbackTransaction317(owner,65536,{tx=>
                tx.withCheckedLiveMemoryRollback317(owner,65536,{=>
                    try{for(_ in 0..2){tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('partial',1,'retain','{}',1)", [])}}
                    catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
                },{actual=>
                    state.original=actual.message
                    @Expect(tx.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
                    @Expect(tx.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),(Int64.Max-1).toString())
                    state.acknowledged=true
                })
            })}catch(error:LiveMemoryRollbackCleanupFailure317){state.original=error.original.message;state.debt=true}
            @Expect(state.original.startsWith("SQLite step failed with code 13:"),true)
            @Expect(state.acknowledged || state.debt,true)
            @Expect(state.acknowledged && state.debt,false)
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
            @Expect(db.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),(Int64.Max-1).toString())
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func CallbackOnlyTransactionCannotManufacturePhysicalRollbackAcknowledgement():Unit{
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        let state=LiveMemoryRollbackTestState317()
        let fake=SqliteTransaction({_=>state.calls++},{_=>[]},{_,_=>state.calls++},{_,_=>[]})
        try{
            try{fake.withCheckedLiveMemoryRollback317(owner,65536,{=>state.action=true},{_=>state.acknowledged=true})}
            catch(_:Exception){state.refused=true}
            @Expect(state.refused,true);@Expect(state.action,false);@Expect(state.acknowledged,false);@Expect(state.calls,0)
        }finally{owner.close()}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func OrdinaryActualReadAndWriteTransactionsCannotEnterOptInScope():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/ordinary.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        let state=LiveMemoryRollbackTestState317()
        let attempt:(SqliteTransaction)->Unit={tx=>
            try{tx.withCheckedLiveMemoryRollback317(owner,65536,{=>state.action=true},{_=>state.acknowledged=true})}
            catch(_:Exception){state.calls++}
        }
        try{db.transaction<Unit>(attempt);db.readTransaction<Unit>(attempt)
            @Expect(state.calls,2);@Expect(state.action,false);@Expect(state.acknowledged,false)
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func SameActualScopeIsOneShotAndRetiredActualTransactionCannotAcknowledge():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/oneshot.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        let state=LiveMemoryRollbackTestState317()
        let other=budget.acquire(65536)
        try{
            db.withLiveMemoryRollbackTransaction317(owner,65536,{tx=>
                state.stale=Some(tx)
                var wrongAllocation=false
                try{tx.withCheckedLiveMemoryRollback317(other,65536,{=>state.calls++},{_=>state.calls+=100})}
                catch(_:Exception){wrongAllocation=true}
                @Expect(wrongAllocation,true);@Expect(state.calls,0)
                tx.withCheckedLiveMemoryRollback317(owner,65536,{=>state.calls++},{_=>state.calls+=100})
                try{tx.withCheckedLiveMemoryRollback317(owner,65536,{=>state.calls++},{_=>state.calls+=100})}
                catch(_:Exception){state.refused=true}
            })
            @Expect(state.calls,1);@Expect(state.refused,true)
            var retired=false
            try{state.stale.getOrThrow().withCheckedLiveMemoryRollback317(owner,65536,{=>state.calls++},{_=>state.calls+=100})}
            catch(_:Exception){retired=true}
            @Expect(retired,true);@Expect(state.calls,1)
        }finally{state.stale=None<SqliteTransaction>;other.close();owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
}
