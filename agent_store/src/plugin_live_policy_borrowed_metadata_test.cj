package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

// Descriptive missing references exercise genuine SQLite fail-closed paths.
// They do not create a completed fact, Source, Root or successful terminal.
func liveBorrowedMissingReference():ContextReadFactLink{
    let digest=modelPolicySha256Text("missing metadata")
    let origin=ContextReadOrigin("axyndra:missing","sha256:"+digest,digest,digest,digest,"missing-request","")
    ContextReadFactLink(OperationId("missing-read"),RunId("missing-run"),ItemId("missing-call"),
        ItemId("missing-result"),"missing-receipt",origin,digest,1)
}
@Test
class PluginLivePolicyBorrowedMetadataTests{
    @TestCase
    func MissingCompletedMetadataCannotRefundBorrowedPhysicalCleanupDebt():Unit{
        let directory=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(directory+"/borrowed.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let debt=pool.acquire(4194304);let phase=pool.acquire(65536)
        try{
            @Expect(pool.usage()[1],134217728)
            db.readTransaction<Unit>({tx=>
                var rejected=false
                try{let _=ContextReadCompletedMetadataPayment(tx,liveBorrowedMissingReference(),{bytes=>pool.acquire(bytes)},
                    {=>Result<Unit>.Ok(())},phaseOwner:Some(phase),extraRetained:1048576)}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(pool.usage()[0],4);@Expect(pool.usage()[1],134217728)})
        }finally{phase.close();debt.close();session.close();output.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func DefaultFailedMetadataClosesOnlyItsOriginalInternalOwner():Unit{
        let directory=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(directory+"/default.sqlite")
        let pool=LogicalJsonOwnerBudget();let unrelated=pool.acquire(65536)
        try{
            db.readTransaction<Unit>({tx=>
                var rejected=false
                try{let _=ContextReadCompletedMetadataPayment(tx,liveBorrowedMissingReference(),{bytes=>pool.acquire(bytes)},
                    {=>Result<Unit>.Ok(())})}catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)})
        }finally{unrelated.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func CancelledBorrowedMetadataDoesNotAcknowledgeCallerReservation():Unit{
        let directory=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(directory+"/cancel.sqlite")
        let pool=LogicalJsonOwnerBudget();let phase=pool.acquire(65536)
        try{
            db.readTransaction<Unit>({tx=>
                var rejected=false
                try{let _=ContextReadCompletedMetadataPayment(tx,liveBorrowedMissingReference(),{bytes=>pool.acquire(bytes)},
                    {=>Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"metadata.cancelled","actual cancellation"))},
                    phaseOwner:Some(phase),extraRetained:1048576)}catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)})
        }finally{phase.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func NestedActualSqliteCellsPayTheSumOfAllRetainedRawAndDomPhases():Unit{
        let directory=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(directory+"/nested.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let owner=pool.acquire(65536)
        let raw=encodeStoredValue(textValue(String.fromUtf8(Array<Byte>(2097152,repeat:65))))
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE phase_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO phase_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                let cell=contextReadMetadataMeasure(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})
                let peak=contextReadMetadataPeak(cell.bytes,cell.nodes)
                withLivePolicyStoredValueOwned(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},
                    {=>Result<Unit>.Ok(())},owner,1048576,{outer=>
                        @Expect(outer,raw)
                        let retained=journalStreamAdd(1048576,peak)
                        withLivePolicyStoredValueOwned(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},
                            {=>Result<Unit>.Ok(())},owner,retained,{inner=>
                                @Expect(inner,outer)
                                @Expect(pool.usage()[0],3)
                                @Expect(pool.usage()[1]>=83886080+journalStreamAdd(retained,peak),true)})})
                @Expect(pool.usage()[0],3)}
        }finally{owner.close();session.close();output.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
