package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

func fixedTextWriterTestDigest(bytes:Array<Byte>):String {
    let hash=SHA256();hash.write(bytes);logicalJsonEncodeHex(hash.finish())
}
func fixedTextWriterTestBefore(db:SqliteDatabase):Unit {
    db.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('fixed-writer',NULL,'fact','before',1)")
}
class FixedTextWriterTestGuard {var stale=false}

@Test
class FixedJournalTextWriterTests {
    @TestCase
    func actualTextTypeUtf8AndEmbeddedZerosKeepOriginalBytes():Unit {
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/writer.sqlite")
        let pool=LogicalJsonOwnerBudget();let value="雪🙂\u{0000}legacy\n";let bytes=value.toArray()
        try {
            fixedTextWriterTestBefore(db)
            db.transaction({tx=>
                let observed=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,bytes.size,
                    fixedTextWriterTestDigest(bytes),{=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},
                    {emit=>for(index in 0..bytes.size){emit(index,[bytes[index]])}})
                @Expect(observed.bytes,bytes.size)
            })
            let rows=db.query("SELECT payload,typeof(payload) FROM memories WHERE rowid=1")
            @Expect(rows[0].required(0),value);@Expect(rows[0].required(1),"text")
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func swallowedProducerErrorStillPoisonsTheOriginalTransaction():Unit {
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/writer.sqlite")
        let pool=LogicalJsonOwnerBudget();let bytes="valid".toArray();var rejected=false
        try {
            fixedTextWriterTestBefore(db)
            try {
                db.transaction({tx=>
                    // Both producer and transaction caller try swallowing the
                    // bad offset; neither can convert it into a valid commit.
                    try {
                        let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,bytes.size,
                            fixedTextWriterTestDigest(bytes),{=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},
                            {emit=>
                                try {emit(1,bytes)}catch(_:Exception){()}
                                try {emit(0,bytes)}catch(_:Exception){()}
                            })
                    } catch(_:Exception){()}
                })
            } catch(_:Exception){rejected=true}
            @Expect(rejected,true)
            @Expect(db.query("SELECT payload FROM memories WHERE rowid=1")[0].required(0),"before")
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func guardLossAfterPartialWriteRollsBackAndReleasesActualOwner():Unit {
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/writer.sqlite")
        let pool=LogicalJsonOwnerBudget();let guard=FixedTextWriterTestGuard();let bytes="valid".toArray()
        var rejected=false
        try {
            fixedTextWriterTestBefore(db)
            try {
                db.transaction({tx=>
                    let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,bytes.size,
                        fixedTextWriterTestDigest(bytes),{=>
                            if(guard.stale){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"fixed_writer_test.guard_stale","test guard changed"))}
                            else{Result<Unit>.Ok(())}},
                        {n=>pool.acquire(n)},{emit=>emit(0,[bytes[0]]);guard.stale=true;emit(1,bytes[1..bytes.size])})
                })
            } catch(_:Exception){rejected=true}
            @Expect(rejected,true)
            @Expect(db.query("SELECT payload FROM memories WHERE rowid=1")[0].required(0),"before")
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func realPoolRejectsBothSqliteBuffersBeforeSqlAndNearEightMiBRemainsExact():Unit {
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/writer.sqlite")
        let pool=LogicalJsonOwnerBudget();let block=Array<Byte>(65536,{index:Int64=>UInt8(32+index%95)})
        let count:Int64=1008;let bytes:Int64=count*65536;let expected=SHA256()
        for(_ in 0..count){expected.write(block)}
        let digest=logicalJsonEncodeHex(expected.finish())
        let pressure=[pool.acquire(1),pool.acquire(1),pool.acquire(1),pool.acquire(1)]
        try {
            fixedTextWriterTestBefore(db);var rejected=false
            try {
                db.transaction({tx:SqliteTransaction=>let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,bytes,digest,
                    {=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},
                    {emit=>for(index in 0..count){emit(index*65536,block)}})})
            } catch(_:LogicalJsonPayloadError){rejected=true}
            @Expect(rejected,true)
            @Expect(db.query("SELECT payload FROM memories WHERE rowid=1")[0].required(0),"before")
            for(owner in pressure){owner.close()}
            // Even without competing owners, two 63 MiB SQL buffers plus
            // 4 MiB scratch exceed the unchanged original 128 MiB pool.
            var standaloneRejected=false
            try {
                db.transaction({tx:SqliteTransaction=>let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,bytes,digest,
                    {=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},
                    {emit=>for(index in 0..count){emit(index*65536,block)}})})
            } catch(_:LogicalJsonPayloadError){standaloneRejected=true}
            @Expect(standaloneRejected,true)
            @Expect(db.query("SELECT payload FROM memories WHERE rowid=1")[0].required(0),"before")
            let full:Int64=127;let tail=block[0..65535];let legalBytes:Int64=full*65536+tail.size
            let legalHash=SHA256();for(_ in 0..full){legalHash.write(block)};legalHash.write(tail)
            let legalDigest=logicalJsonEncodeHex(legalHash.finish())
            db.transaction({tx:SqliteTransaction=>
                let observed=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,1,legalBytes,legalDigest,
                    {=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},
                    {emit=>for(index in 0..full){emit(index*65536,block)};emit(full*65536,tail)})
                @Expect(observed.bytes,8388607);@Expect(observed.digest,legalDigest)
            })
            let observed=db.readTransaction({tx=>tx.readFixedJournalCell(FixedJournalCell.CurrentPayload,1,None,
                {=>Result<Unit>.Ok(())},{n=>pool.acquire(n)},None)})
            @Expect(observed.bytes,legalBytes);@Expect(observed.digest,legalDigest)
            @Expect(db.query("SELECT typeof(payload) FROM memories WHERE rowid=1")[0].required(0),"text")
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        } finally {for(owner in pressure){owner.close()};db.close();remove(root,recursive:true)}
    }
}
