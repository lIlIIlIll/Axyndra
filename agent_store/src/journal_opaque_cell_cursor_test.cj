package agent_store

import agent_domain.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

func opaqueCellTestCurrent():Result<Unit>{Result<Unit>.Ok(())}
func opaqueCellTestRead(cursor:JournalOpaqueCellCursor):JournalOpaqueCellObservation{
    try{while(!cursor.next().isEmpty()){};cursor.finish()}finally{cursor.close()}
}
class OpaqueCellTestState {
    var cancelled=false
    var cursor:?JournalOpaqueCellCursor=None
    var transaction:?SqliteTransaction=None
}

@Test
class JournalOpaqueCellCursorTests {
    @TestCase
    func GenericTypeAndRawBytesKeepNullTextBlobIntegerAndExactRealDistinct():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/opaque.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864,maximumMessage:65536)
        try{
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(0,'zero',NULL,'opaque',X'610062',1.25)")
            db.readTransaction<Unit>({tx=>
                let a=tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,0,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)})
                let b=tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentThread,0,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)})
                @Expect(a.sqliteType,"blob");@Expect(b.sqliteType,"null")
                @Expect(opaqueCellTestRead(a).digest,modelPolicySha256([b'a',UInt8(0),b'b']))
                @Expect(opaqueCellTestRead(b).digest,modelPolicySha256([]))
                let text=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentId,0,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                @Expect(text.sqliteType,"text");@Expect(text.digest,modelPolicySha256Text("zero"))
                let real=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentRevision,0,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                @Expect(real.sqliteType,"real");@Expect(real.bytes,8)
                let bits=Float64(1.25).toBits()
                @Expect(real.digest,modelPolicySha256(Array<Byte>(8,{offset=>UInt8((bits>>UInt64((7-offset)*8))&0xFF)})))
            })
            db.execute("UPDATE memories SET revision=-9223372036854775808 WHERE rowid=0")
            db.readTransaction<Unit>({tx=>
                let integer=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentRevision,0,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                @Expect(integer.sqliteType,"integer");@Expect(integer.digest,modelPolicySha256Text("-9223372036854775808"))
            })
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func CompleteInt64RowidsAndIgnoredMetadataDoNotAcquireNewCodecRestrictions():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/opaque.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            for(id in [Int64.Min,Int64(-1),Int64(0),Int64.Max]){
                db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,?,'ignored',X'00',?,X'ff')",
                    [SqlParameter.Int64Value(id),SqlParameter.Text("opaque-"+id.toString()),SqlParameter.Text("{\"value\":\"original\"}")])
            }
            db.readTransaction<Unit>({tx=>
                for(id in [Int64.Min,Int64(-1),Int64(0),Int64.Max]){
                    let body=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.EventPayload,id,None,true,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                    @Expect(body.digest,modelPolicySha256Text("{\"value\":\"original\"}"))
                    let revision=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.EventRevision,id,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                    @Expect(revision.sqliteType,"text");@Expect(revision.digest,modelPolicySha256Text("ignored"))
                    let time=opaqueCellTestRead(tx.openJournalOpaqueCell(JournalOpaqueCell.EventCreatedAt,id,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
                    @Expect(time.sqliteType,"blob");@Expect(time.digest,modelPolicySha256([UInt8(255)]))
                }
            })
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func SixtyThreeMiBOpaqueTextUsesOnlyFixedWindowsAndCompleteActualBytes():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/opaque.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            // Trusted seed only; no large managed String and no fake Source.
            db.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('large',NULL,'opaque',hex(zeroblob(33030144)),1)")
            let expected=SHA256();let block=Array<Byte>(65536,repeat:b'0')
            for(_ in 0..1008){expected.write(block)}
            db.readTransaction<Unit>({tx=>
                let id=Int64.parse(tx.query("SELECT rowid FROM memories WHERE id='large'")[0].required(0))
                let cursor=tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,id,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)})
                try{
                    @Expect(cursor.bytes,66060288)
                    while(true){let bytes=cursor.next();if(bytes.isEmpty()){break};@Expect(bytes.size<=65536,true)}
                    @Expect(cursor.finish().digest,logicalJsonEncodeHex(expected.finish()))
                }finally{cursor.close()}
            })
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func ExpectedWholeTypeHashAndCurrentCancellationFailWithoutAnAcknowledgedRead():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/opaque.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:33554432,maximumMessage:65536)
        try{
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(-1,'known',NULL,'opaque','body',1)")
            db.readTransaction<Unit>({tx=>
                let wrong=JournalOpaqueCellObservation("text",4,modelPolicySha256Text("different"))
                let cursor=tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,-1,Some(wrong),false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)})
                var mismatch=false
                try{while(!cursor.next().isEmpty()){};let _=cursor.finish()}catch(_:Exception){mismatch=true}finally{cursor.close()}
                @Expect(mismatch,true)
                let state=OpaqueCellTestState()
                let cancelled=tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,-1,None,false,{=>
                    if(state.cancelled){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","cancelled data owner"))}
                    else{Result<Unit>.Ok(())}},{bytes=>budget.acquire(bytes)})
                state.cancelled=true;var refused=false
                try{let _=cancelled.next()}catch(_:Exception){refused=true}finally{cancelled.close()}
                @Expect(refused,true)
            })
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func TransactionRefusesALiveCursorAndCleanupInvalidatesEveryEscapedHandle():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/opaque.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536);let state=OpaqueCellTestState()
        try{
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(1,'known',NULL,'opaque','body',1)")
            var live=false
            try{db.readTransaction<Unit>({tx=>
                state.transaction=Some(tx)
                state.cursor=Some(tx.openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,1,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)}))
            })}catch(_:Exception){live=true}
            @Expect(live,true);@Expect(state.cursor.getOrThrow().isClosed(),true)
            var escaped=false;try{let _=state.cursor.getOrThrow().next()}catch(_:Exception){escaped=true};@Expect(escaped,true)
            var closed=false
            try{let _=state.transaction.getOrThrow().openJournalOpaqueCell(JournalOpaqueCell.CurrentPayload,1,None,false,opaqueCellTestCurrent,{bytes=>budget.acquire(bytes)})}
            catch(_:Exception){closed=true};@Expect(closed,true)
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
}
