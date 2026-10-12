package agent_store
import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OpaqueJournalAppendPredictionTests{
    @TestCase
    func PredictsOriginalCompleteFutureStateFor129EventsBeforeAnyMutation():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/predict.db");let owner=LogicalJsonOwnerBudget()
        try{
            database.transaction<Unit>({tx=>
                let before=streamOpaqueRowJournalFence(tx,{bytes=>owner.acquire(bytes)},{=>Result<Unit>.Ok(())})
                let entries=ArrayList<OpaqueRowJournalPreparedAppend>()
                for(index in 1..130){
                    let body="雪🐈\n"+index.toString();let bytes=body.toArray()
                    entries.add(OpaqueRowJournalPreparedAppend(index,"id-"+index.toString(),1,"preference","retain",index,
                        bytes.size,modelPolicySha256(bytes),{consume=>consume(bytes)}))}
                let predicted=predictOpaqueRowJournalAppendFence(tx,before,entries.toArray(),{bytes=>owner.acquire(bytes)},{=>Result<Unit>.Ok(())})
                @Expect(tx.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"0")
                for(index in 1..130){let body="雪🐈\n"+index.toString()
                    tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,?,1,'retain',?,?)",
                        [SqlParameter.Int64Value(index),SqlParameter.Text("id-"+index.toString()),SqlParameter.Text(body),SqlParameter.Int64Value(index)])
                    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'preference',?,1)",
                        [SqlParameter.Text("id-"+index.toString()),SqlParameter.Text(body)])}
                let independent=journalStreamTestExpected(tx)
                @Expect(predicted.rows,129);@Expect(predicted.events,129);@Expect(predicted.nextEvent,130)
                @Expect(predicted.chain,independent[0]);@Expect(predicted.digest,independent[1])
                // The expected fence was computed before mutation. A trigger
                // changing an unrelated original row cannot redefine it.
                tx.execute("UPDATE memories SET kind='fact' WHERE id='id-1'")
                let tampered=streamOpaqueRowJournalFence(tx,{bytes=>owner.acquire(bytes)},{=>Result<Unit>.Ok(())})
                @Expect(tampered.digest!=predicted.digest)
            })
        }finally{database.close();remove(root,recursive:true)}
    }
}
