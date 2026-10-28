package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

@Test
class FixedJournalColumnObservationTests {
    @TestCase
    func ActualBlobMeasureAndHashAreCompleteAndThenPinTheSecondBoundedPass():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/observed.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{let raw=String.fromUtf8(Array<Byte>(65535,repeat:b'x'))+"音楽\u{0000}🐈end"
            blobContractSeed(database,"original",raw)
            database.readTransaction<Unit>({tx=>
                for(event in [false,true]){
                    let observation=tx.observeOpaqueJournalColumn(event,if(event){""}else{"original"},if(event){1}else{0},
                        blobContractOkay,{bytes=>budget.acquire(bytes)})
                    @Expect(observation.bytes,raw.size);@Expect(observation.digest,modelPolicySha256Text(raw))
                    @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
                    let hash=SHA256();let progress=FixedJournalBlobTestProgress()
                    tx.streamOpaqueJournalColumn(event,if(event){""}else{"original"},if(event){1}else{0},observation.bytes,
                        blobContractOkay,{bytes=>budget.acquire(bytes)},{offset,bytes=>
                            @Expect(offset,progress.seen);progress.seen+=bytes.size;hash.write(bytes)})
                    @Expect(progress.seen,observation.bytes);@Expect(logicalJsonEncodeHex(hash.finish()),observation.digest)
                }
            })
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func SixtyThreeMiBObservedCodecTextDoesNotNeedLengthCastOrAWholePayloadString():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/observed.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        let prefix="{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"large\",\"kind\":\"project_fact\",\"scopeKind\":\"global\",\"scopeKey\":\"\",\"content\":\""
        let suffix="\",\"status\":\"active\"}}"
        try{
            // Seed-only SQLite construction; the read never builds a large
            // managed payload, asks SQL length/CAST(payload), or loads its
            // column through query(). This is not a Native/business gate.
            database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('large',NULL,'project_fact',? || hex(zeroblob(33030144)) || ?,1)",
                [SqlParameter.Text(prefix),SqlParameter.Text(suffix)])
            let expected=SHA256();expected.write(prefix.toArray())
            let block=Array<Byte>(65536,repeat:b'0');for(_ in 0..1008){expected.write(block)};expected.write(suffix.toArray())
            database.readTransaction<Unit>({tx=>
                let observation=tx.observeOpaqueJournalColumn(false,"large",0,blobContractOkay,{bytes=>budget.acquire(bytes)})
                @Expect(observation.bytes,66060288+prefix.size+suffix.size)
                @Expect(observation.digest,logicalJsonEncodeHex(expected.finish()))
                @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
            })
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func ClosedUnownedWrongTypeAndCancellationNeverReturnAnObservedColumn():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/observed.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536)
        try{blobContractSeed(database,"original","private original")
            database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('binary',NULL,'project_fact',zeroblob(13),1)")
            let progress=FixedJournalBlobTestProgress()
            database.readTransaction<Unit>({tx=>
                progress.escaped=Some(tx)
                @Expect(blobContractFails({=>let _=tx.observeOpaqueJournalColumn(false,"binary",0,blobContractOkay,{bytes=>budget.acquire(bytes)})}),true)
                @Expect(blobContractFails({=>let _=tx.observeOpaqueJournalColumn(false,"missing",0,blobContractOkay,{bytes=>budget.acquire(bytes)})}),true)
                @Expect(blobContractFails({=>let _=tx.observeOpaqueJournalColumn(true,"original",1,blobContractOkay,{bytes=>budget.acquire(bytes)})}),true)
                @Expect(blobContractFails({=>let _=tx.observeOpaqueJournalColumn(false,"original",0,{=>
                    Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","cancelled actual data scope"))},
                    {bytes=>budget.acquire(bytes)})}),true)
            })
            @Expect(blobContractFails({=>let _=progress.escaped.getOrThrow().observeOpaqueJournalColumn(false,"original",0,
                blobContractOkay,{bytes=>budget.acquire(bytes)})}),true)
            let unowned=SqliteTransaction({_:String=>()},{_:String=>Array<SqliteRow>()},
                {_:String,_:Array<SqlParameter>=>()},{_:String,_:Array<SqlParameter>=>Array<SqliteRow>()})
            @Expect(blobContractFails({=>let _=unowned.observeOpaqueJournalColumn(false,"original",0,
                blobContractOkay,{bytes=>budget.acquire(bytes)})}),true)
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{database.close();remove(root,recursive:true)}
    }
}
