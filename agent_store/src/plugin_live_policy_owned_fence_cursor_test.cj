package agent_store

import agent_domain.*
import std.convert.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

// Actual SQLite, native blob handles, original full fence and real pool
// controls only. These generic cells create no read Source/Root/Receipt.
class LiveOwnedCursorState {var cancelled=false;var cursor:?JournalOpaqueCellCursor=None;var transaction:?SqliteTransaction=None}
@Test
class PluginLivePolicyOwnedFenceCursorTests {
    @TestCase
    func WholePrivateFenceMatchesOriginalAcrossAllInt64RowsAndSqliteTypes():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/whole.sqlite")
        let policy=latestViewTestPolicies();let oraclePool=LogicalJsonOwnerBudget(maximumCharged:67108864)
        let oracle=JournalLatestStreamStorage(policy[0],policy[1],"/actual",{bytes=>oraclePool.acquire(bytes)})
        let pool=LogicalJsonOwnerBudget();let actual=JournalLatestStreamStorage(policy[0],policy[1],"/actual",{bytes=>pool.acquire(bytes)})
        try {
            for(rowid in [Int64.Min,Int64(-1),Int64(0),Int64.Max]) {
                db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,CAST(? AS TEXT),1.25,X'00',X'FF0061',-9223372036854775808)",[SqlParameter.Int64Value(rowid),SqlParameter.Int64Value(rowid)])}
            db.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('nullable-control',NULL,'opaque',X'FF0061',1)")
            let expected=db.readTransaction<JournalLatestStreamFence>({tx=>oracle.fence(tx,opaqueCellTestCurrent)})
            @Expect(oraclePool.usage()[0],0);@Expect(oraclePool.usage()[1],0)
            let output=pool.acquire(8388608);let session=pool.acquire(65536);let registry=pool.acquire(65536)
            let owner=pool.acquire(65536);let fixed=pool.acquireFixedBuffer(65536)
            try {
                db.readTransaction<Unit>({tx=>
                    let observed=actual.fenceOwned(tx,opaqueCellTestCurrent,owner,1048576)
                    @Expect(observed.same(expected),true);@Expect(observed.events,4)
                    @Expect(pool.usage()[0],5);@Expect(pool.usage()[1],117506048)})
                @Expect(pool.usage()[0],5)
            }finally{fixed.close();owner.close();registry.close();session.close();output.close()}
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func SixtyThreeMiBOpaqueBodyUsesActualFixedCursorAndKeepsBorrowerCharged():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/large.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let registry=pool.acquire(65536);let owner=pool.acquire(65536);let fixed=pool.acquireFixedBuffer(65536)
        try {
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(0,'large',NULL,'opaque',hex(zeroblob(33030144)),1)")
            let expected=SHA256();let chunk=Array<Byte>(65536,repeat:b'0')
            for(_ in 0..1008){expected.write(chunk)}
            db.readTransaction<Unit>({tx=>
                let cursor=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,0,None,false,opaqueCellTestCurrent,owner,1048576)
                try {
                    @Expect(cursor.bytes,66060288)
                    while(true){let bytes=cursor.next();if(bytes.isEmpty()){break};@Expect(bytes.size<=65536,true)}
                    @Expect(cursor.finish().digest,logicalJsonEncodeHex(expected.finish()))
                }finally{cursor.close()}
                @Expect(cursor.isClosed(),true);@Expect(pool.usage()[0],5);@Expect(pool.usage()[1],117506048)})
        }finally{fixed.close();owner.close();registry.close();session.close();output.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ExpectedWholeHashAndPrematureEofRefuseWithoutRefundingBorrower():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/hash.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        try {
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(-1,'known',NULL,'opaque','whole',1)")
            db.readTransaction<Unit>({tx=>
                let early=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,-1,None,false,opaqueCellTestCurrent,owner,1048576)
                var refused=false
                try{let _=early.finish()}catch(_:Exception){refused=true}finally{early.close()}
                @Expect(refused,true);@Expect(pool.usage()[0],1)
                let wrong=JournalOpaqueCellObservation("text",5,modelPolicySha256Text("other"))
                let cursor=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,-1,Some(wrong),false,opaqueCellTestCurrent,owner,1048576)
                var mismatch=false
                try{while(!cursor.next().isEmpty()){};let _=cursor.finish()}catch(_:Exception){mismatch=true}finally{cursor.close()}
                @Expect(mismatch,true);@Expect(pool.usage()[0],1)})
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ActualCurrentCancellationClosesPhysicalCursorButNotCallerOwner():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/cancel.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536);let state=LiveOwnedCursorState()
        try {
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(1,'known',NULL,'opaque','whole',1)")
            db.readTransaction<Unit>({tx=>
                let cursor=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,1,None,false,{=>
                    if(state.cancelled){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"cursor.cancelled","actual cancellation"))}
                    else{Result<Unit>.Ok(())}},owner,1048576)
                state.cancelled=true;var refused=false
                try{let _=cursor.next()}catch(_:Exception){refused=true}finally{cursor.close()}
                @Expect(refused,true);@Expect(cursor.isClosed(),true);@Expect(pool.usage()[0],1)})
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func SameOriginalRegistryRefusesLiveBorrowedCursorAndInvalidatesStaleTx():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/debt.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536);let state=LiveOwnedCursorState()
        try {
            db.execute("INSERT INTO memories(rowid,id,thread_id,kind,payload,revision) VALUES(1,'known',NULL,'opaque','whole',1)")
            var refused=false
            try{db.readTransaction<Unit>({tx=>
                state.transaction=Some(tx)
                state.cursor=Some(tx.openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,1,None,false,opaqueCellTestCurrent,owner,1048576))
            })}catch(_:Exception){refused=true}
            @Expect(refused,true);@Expect(state.cursor.getOrThrow().isClosed(),true);@Expect(pool.usage()[0],1)
            var stale=false
            try{let _=state.transaction.getOrThrow().openJournalOpaqueCellOwned(JournalOpaqueCell.CurrentPayload,1,None,false,opaqueCellTestCurrent,owner,1048576)}
            catch(_:Exception){stale=true}
            @Expect(stale,true);@Expect(pool.usage()[0],1)
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func CompleteModelBlockComparisonKeepsExpectedAndActualInOneChargedPhase():Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/model.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let registry=pool.acquire(65536);let owner=pool.acquire(65536);let fixed=pool.acquireFixedBuffer(65536)
        let raw=encodeStoredValue(objectValue([ValueField("kind",textValue("tool_call")),ValueField("arguments",textValue("complete unchanged"))]))
        try {
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE model_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO model_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                withLivePolicyStoredValueOwned(tx,"payload"," FROM model_cell",[],{bytes=>pool.acquire(bytes)},opaqueCellTestCurrent,
                    owner,contextReadMetadataRawPeak(raw.size),{actual=>
                        @Expect(actual,raw);@Expect(pool.usage()[0],5);@Expect(pool.usage()[1],117506048)})}
        }finally{fixed.close();owner.close();registry.close();session.close();output.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
