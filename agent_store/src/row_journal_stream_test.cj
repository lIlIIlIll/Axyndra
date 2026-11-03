package agent_store



import agent_domain.*

import std.collection.*

import std.convert.*

import std.env.getVariable
import std.fs.*

import std.unittest.*

import std.unittest.testmacro.*

import yjson.*

import yjson_support.*



// Test reference holder preserves the original delayed callback counter.
class JournalStreamTestChecks {var value:Int64=0}

func journalStreamTestExpected(transaction:SqliteTransaction):Array<String>{

    let rows=transaction.query("SELECT id,thread_id,kind,payload,revision FROM memories ORDER BY id")

    let events=transaction.query("SELECT id,memory_id,revision,operation,payload,created_at_millis FROM memory_events ORDER BY id")

    let current=rows.map{row:SqliteRow=>objectValue([ValueField("key",textValue(row.required(0))),ValueField("kind",textValue(row.required(2))),

        ValueField("payload_sha256",textValue(modelPolicySha256Text(row.required(3)))),ValueField("revision",integerValue(Int64.parse(row.required(4))))])}

    let history=events.map{row:SqliteRow=>objectValue([ValueField("id",integerValue(Int64.parse(row.required(0)))),ValueField("key",textValue(row.required(1))),

        ValueField("revision",integerValue(Int64.parse(row.required(2)))),ValueField("operation",textValue(row.required(3))),

        ValueField("payload",textValue(row.required(4))),ValueField("created_at_millis",integerValue(Int64.parse(row.required(5))))])}

    let sequence=transaction.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")

    let next=if(sequence.isEmpty()){1}else{Int64.parse(sequence[0].required(0))+1}

    var chain=modelPolicySha256Text("axyndra.opaque-row-journal/v1")

    for(event in history){chain=modelPolicySha256Text(chain+canonicalAgentValue(event))}

    [chain,modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("rows",listValue(current)),ValueField("events",listValue(history)),ValueField("next_event_id",integerValue(next))])))]

}

@Test

class OpaqueRowJournalStreamingFenceTests{

    @TestCase

    func StreamingFencePreservesEveryOriginalCanonicalByteAndUnicodeChunkBoundary():Unit{

        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/stream.db")

        let owner=LogicalJsonOwnerBudget()

        try{

            for(index in 1..4){

                let content=String.fromUtf8(Array<Byte>(65535+index,repeat:65))+"雪🐈"+index.toString()

                database.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,?)",

                    [SqlParameter.Text("id-"+index.toString()),SqlParameter.Text(content),SqlParameter.Int64Value(index)])

                database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'preference',?,1)",

                    [SqlParameter.Text("id-"+index.toString()),SqlParameter.Text(content)])}

            database.readTransaction<Unit>({tx=>

                let expected=journalStreamTestExpected(tx)

                let actual=streamOpaqueRowJournalFence(tx,{bytes=>owner.acquire(bytes)},{=>Result<Unit>.Ok(())})

                @Expect(actual.chain,expected[0]);@Expect(actual.digest,expected[1]);@Expect(actual.rows,3);@Expect(actual.events,3)

                @Expect(actual.nextEvent,4)

            })

        }finally{database.close();remove(root,recursive:true)}

    }

    @TestCase

    func CurrentBoundaryFailureInterruptsTheScanWithoutChangingAnySqliteFact():Unit{

        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/stream.db")

        let owner=LogicalJsonOwnerBudget();let checks=JournalStreamTestChecks()

        try{

            let bytes=String.fromUtf8(Array<Byte>(6*1024*1024,repeat:65))

            database.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES('large',1,'retain',?,1)",[SqlParameter.Text(bytes)])

            database.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('large',NULL,'preference',?,1)",[SqlParameter.Text(bytes)])

            var denied=false

            try{database.readTransaction<Unit>({tx=>let _=streamOpaqueRowJournalFence(tx,{bytes=>owner.acquire(bytes)},{=>

                checks.value++;if(checks.value>10){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.scan_cancelled","current boundary cancelled"))}

                else{Result<Unit>.Ok(())}})})}catch(_:Exception){denied=true}

            @Expect(denied);@Expect(checks.value>10)

            @Expect(database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)

            @Expect(database.query("SELECT payload FROM memories WHERE id='large'")[0].required(0),bytes)

        }finally{database.close();remove(root,recursive:true)}

    }

}

