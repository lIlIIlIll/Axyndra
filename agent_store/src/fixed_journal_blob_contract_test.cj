package agent_store

import agent_domain.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

class FixedJournalBlobTestProgress {
    var seen:Int64=0
    var chunks:Int64=0
    var count:Int64=0
    var cancelled=false
    var escaped:?SqliteTransaction=None
}
func blobContractOkay():Result<Unit>{Result<Unit>.Ok(())}
func blobContractSeed(database:SqliteDatabase,id:String,payload:String):Unit{
    database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'project_fact',?,1)",
        [SqlParameter.Text(id),SqlParameter.Text(payload)])
    database.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,1)",
        [SqlParameter.Text(id),SqlParameter.Text(payload)])
}
func blobContractFails(body:()->Unit):Bool{try{body();false}catch(_:Exception){true}}

@Test
class FixedJournalBlobContractTests{
    @TestCase
    func SameActualTransactionStreamsTextBytesAndNulWithoutWholeColumnConversion():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            let raw=String.fromUtf8(Array<Byte>(65535,repeat:b'x'))+"音楽\u{0000}🐈end"
            blobContractSeed(database,"unicode",raw)
            database.readTransaction<Unit>({tx=>
                for(event in [false,true]){
                    let hash=SHA256();let progress=FixedJournalBlobTestProgress()
                    tx.streamOpaqueJournalColumn(event,if(event){""}else{"unicode"},if(event){1}else{0},raw.size,
                        blobContractOkay,{bytes=>owner.acquire(bytes)},{offset,bytes=>
                            @Expect(offset,progress.seen);@Expect(bytes.size<=65536,true)
                            progress.seen+=bytes.size;progress.chunks++;hash.write(bytes)
                            @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],16777216)})
                    @Expect(progress.seen,raw.size);@Expect(progress.chunks,2)
                    @Expect(logicalJsonEncodeHex(hash.finish()),modelPolicySha256Text(raw))
                    @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
                }
            })
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func SixtyThreeMiBStoredTextNeedsOnlyOneBoundedReadReservation():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            // Real sole SQLite storage seed, transport-only: TEXT has NUL
            // bytes and is deliberately not a Native Memory codec fixture.
            // No 63MiB managed String is built to exercise the READ path.
            database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('large',NULL,'project_fact',CAST(zeroblob(66060288) AS TEXT),1)")
            database.readTransaction<Unit>({tx=>
                let progress=FixedJournalBlobTestProgress();let actualHash=SHA256();let expectedHash=SHA256()
                let zeroes=Array<Byte>(65536,repeat:UInt8(0))
                for(_ in 0..1008){expectedHash.write(zeroes)}
                tx.streamOpaqueJournalColumn(false,"large",0,66060288,blobContractOkay,{bytes=>owner.acquire(bytes)},
                    {offset,bytes=>@Expect(offset,progress.seen);@Expect(bytes.size,65536)
                        actualHash.write(bytes)
                        progress.seen+=bytes.size;progress.count++;@Expect(owner.usage()[1],16777216)})
                @Expect(progress.seen,66060288);@Expect(progress.count,1008)
                @Expect(logicalJsonEncodeHex(actualHash.finish()),logicalJsonEncodeHex(expectedHash.finish()))
            })
            @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func FixedMappingTypeLengthAndIdentityChangesCannotReadAnotherColumn():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            blobContractSeed(database,"original","original text")
            database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('binary',NULL,'project_fact',zeroblob(13),1)")
            database.readTransaction<Unit>({tx=>
                let progress=FixedJournalBlobTestProgress();let receive={_:Int64,bytes:Array<Byte>=>progress.seen+=bytes.size}
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(false,"missing",0,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(false,"original",0,12,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(false,"binary",0,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(false,"original",1,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(true,"original",1,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(blobContractFails({=>tx.streamOpaqueJournalColumn(true,"",0,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)}),true)
                @Expect(progress.seen,0);@Expect(owner.usage()[0],0)
                tx.streamOpaqueJournalColumn(false,"original",0,13,blobContractOkay,{bytes=>owner.acquire(bytes)},receive)
                @Expect(progress.seen,13)
            })
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func CancellationAndConsumerFailureCloseActualBlobAndReleaseBudgetBeforeRetry():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            let raw=String.fromUtf8(Array<Byte>(131072,repeat:b'x'));blobContractSeed(database,"cancel",raw)
            let progress=FixedJournalBlobTestProgress()
            @Expect(blobContractFails({=>database.readTransaction<Unit>({tx=>
                tx.streamOpaqueJournalColumn(false,"cancel",0,raw.size,{=>
                    if(progress.cancelled){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.blob_cancelled","actual current scope progress.cancelled"))}
                    else{Result<Unit>.Ok(())}}, {bytes=>owner.acquire(bytes)},
                    {_,bytes=>progress.seen+=bytes.size;progress.cancelled=true})})}),true)
            @Expect(progress.seen,65536);@Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
            @Expect(blobContractFails({=>database.readTransaction<Unit>({tx=>
                tx.streamOpaqueJournalColumn(false,"cancel",0,raw.size,blobContractOkay,{bytes=>owner.acquire(bytes)},
                    {_,_=>throw IllegalStateException("fixture consumer failed")})})}),true)
            @Expect(owner.usage()[0],0)
            database.readTransaction<Unit>({tx=>
                let retryProgress=FixedJournalBlobTestProgress();tx.streamOpaqueJournalColumn(false,"cancel",0,raw.size,blobContractOkay,
                    {bytes=>owner.acquire(bytes)},{_,bytes=>retryProgress.seen+=bytes.size});@Expect(retryProgress.seen,raw.size)})
            @Expect(database.scalarInt("SELECT COUNT(*) FROM memories"),1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func ChangingActualRowExpiresBlobAndRollsBackSameTransaction():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            let raw=String.fromUtf8(Array<Byte>(131072,repeat:b'x'));blobContractSeed(database,"changed",raw)
            let progress=FixedJournalBlobTestProgress()
            @Expect(blobContractFails({=>database.transaction<Unit>({tx=>
                tx.streamOpaqueJournalColumn(false,"changed",0,raw.size,blobContractOkay,{bytes=>owner.acquire(bytes)},
                    {_,bytes=>progress.seen+=bytes.size;if(progress.seen==65536){tx.execute("UPDATE memories SET revision=2 WHERE id='changed'")}})})}),true)
            @Expect(progress.seen,65536);@Expect(owner.usage()[0],0)
            @Expect(database.scalarInt("SELECT revision FROM memories WHERE id='changed'"),1)
            @Expect(database.query("SELECT payload FROM memories WHERE id='changed'")[0].required(0),raw)
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func EscapedTransactionAndPublicUnownedConstructorCannotUseInternalBlobReader():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/blob.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{
            blobContractSeed(database,"owned","original text");let progress=FixedJournalBlobTestProgress()
            database.readTransaction<Unit>({tx=>progress.escaped=Some(tx)})
            @Expect(blobContractFails({=>progress.escaped.getOrThrow().streamOpaqueJournalColumn(false,"owned",0,13,
                blobContractOkay,{bytes=>owner.acquire(bytes)},{_,_=>()})}),true)
            let unowned=SqliteTransaction({_:String=>()},{_:String=>Array<SqliteRow>()},
                {_:String,_:Array<SqlParameter>=>()},{_:String,_:Array<SqlParameter>=>Array<SqliteRow>()})
            @Expect(blobContractFails({=>unowned.streamOpaqueJournalColumn(false,"owned",0,13,
                blobContractOkay,{bytes=>owner.acquire(bytes)},{_,_=>()})}),true)
            @Expect(owner.usage()[0],0)
        }finally{database.close();remove(root,recursive:true)}
    }
}
