package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Independent real SQLite allocator controls, not a Root/settlement fixture.
// The production caller adds its actual private write-authority seam first.
@Test
class LiveMemoryActualWriteAllocationTests309 {
    @TestCase
    func DeletedHighestEventPreservesOriginalAutoincrementHighWater():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/actual-write.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            db.transaction<Unit>({tx=>
                tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(99,'gone',1,'retain','{}',1)", [])
                tx.execute("DELETE FROM memory_events WHERE id=99", [])
                let allocation=liveMemoryActualWriteAllocation309(tx,2,owner,65536,{=>Result<Unit>.Ok(())})
                @Expect(allocation.fits,true);@Expect(allocation.first,100)
                for(id in [100,101]){
                    tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('new',?,'retain','{}',1)", [SqlParameter.Int64Value(id)])
                    @Expect(tx.query("SELECT last_insert_rowid()")[0].required(0),id.toString())
                }
                liveMemoryRequireActualWriteAllocation309(tx,allocation,{=>Result<Unit>.Ok(())})
                tx.execute("UPDATE sqlite_sequence SET seq=105 WHERE name='memory_events'", [])
                var changed=false;try{liveMemoryRequireActualWriteAllocation309(tx,allocation,{=>Result<Unit>.Ok(())})}
                catch(_:Exception){changed=true};@Expect(changed,true)
            })
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func SignedMaximumNeverWrapsOrReusesAnEventId():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/full-write.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            // The baseline is already committed. SQLITE_FULL may end the
            // actual failing TX; never catch inside it and pretend COMMIT is
            // still possible, or expect its uncommitted seed to survive.
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,'last',1,'retain','{}',1)",
                [SqlParameter.Int64Value(Int64.Max)])
            var sqliteMessage=""
            try{db.transaction<Unit>({tx=>
                let allocation=liveMemoryActualWriteAllocation309(tx,1,owner,65536,{=>Result<Unit>.Ok(())})
                @Expect(allocation.fits,false);@Expect(allocation.first,0)
                tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('full',1,'retain','{}',1)", [])
            })}catch(error:Exception){sqliteMessage=error.message}
            @Expect(sqliteMessage.startsWith("SQLite step failed with code 13:"),true)
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
            @Expect(db.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),Int64.Max.toString())
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func EmptyNegativeSequenceAndHigherTableIdUseActualSqliteAllocator():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/numeric-write.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{db.transaction<Unit>({tx=>
            let empty=liveMemoryActualWriteAllocation309(tx,1,owner,65536,{=>Result<Unit>.Ok(())})
            @Expect(empty.fits,true);@Expect(empty.first,1)
            tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(10,'actual',1,'retain','{}',1)", [])
            tx.execute("UPDATE sqlite_sequence SET seq=-100 WHERE name='memory_events'", [])
            let actual=liveMemoryActualWriteAllocation309(tx,1,owner,65536,{=>Result<Unit>.Ok(())})
            @Expect(actual.first,11)
            tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('next',1,'retain','{}',1)", [])
            @Expect(tx.query("SELECT last_insert_rowid()")[0].required(0),"11")
            liveMemoryRequireActualWriteAllocation309(tx,actual,{=>Result<Unit>.Ok(())})
        })}finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func GroupCrossingSignedMaximumRaisesRealSqliteFullAndRollsBack():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/group-full.db")
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,'before',1,'retain','{}',1)",[SqlParameter.Int64Value(Int64.Max-1)])
            var message=""
            try{db.transaction<Unit>({tx=>
                let allocation=liveMemoryActualWriteAllocation309(tx,2,owner,65536,{=>Result<Unit>.Ok(())})
                @Expect(allocation.fits,false)
                for(_ in 0..2){tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('full',1,'retain','{}',1)", [])}
            })}catch(error:Exception){message=error.message}
            @Expect(message.startsWith("SQLite step failed with code 13:"),true)
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
            @Expect(db.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")[0].required(0),(Int64.Max-1).toString())
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }

}
