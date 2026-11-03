package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Allocation/codec tests only. The rows below are generic audit payloads;
// they are not fabricated Sources, approvals or successful child receipts.
// Actual Runtime live-parent/child receipt controls require the later closed
// Store admission and finalization path, not this mechanical helper.
class LiveLedgerPaymentChecks{var value:Int64=0}

@Test
class PluginLivePolicyLedgerPaymentTests{
    @TestCase
    func fullLargeIgnoredReceiptBodyUsesOriginalEofAndReleasesEachPaidPhase():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/ledger-payment.sqlite")
        let pool=LogicalJsonOwnerBudget()
        try{
            let raw=encodeStoredValue(objectValue([ValueField("body",textValue(
                String.fromUtf8(Array<Byte>(6*1024*1024,repeat:65))+"雪🐈"))]))
            database.execute("INSERT INTO audit_events(kind,payload,created_at_millis) VALUES('live_payment_fixture',?,1)",
                [SqlParameter.Text(raw)])
            database.readTransaction<Unit>{tx=>
                let measured=contextReadMetadataMeasure(tx,"payload"," FROM audit_events WHERE kind='live_payment_fixture'",[],
                    {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})
                @Expect(measured.bytes,raw.size);@Expect(measured.nodes>0,true)
                @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
                // Prefix output retains its OWN small reservation after the
                // large ignored metadata phase has physically returned.
                let lease=pool.acquire(65536)
                let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                    ValueField("parent_operation_id",textValue("descriptor-only-parent")),
                    ValueField("through_sequence",integerValue(0)),ValueField("tip",nullValue())])
                let prefix=SqliteLivePolicyReceiptPrefix(reference,lease)
                @Expect(pool.usage()[0],1);@Expect(canonicalAgentValue(prefix.reference()),canonicalAgentValue(reference))
                prefix.close();prefix.close();@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
                var denied=false;try{let _=prefix.reference()}catch(_:Exception){denied=true};@Expect(denied,true)
            }
        }finally{database.close();remove(root,recursive:true)}
    }
    @TestCase
    func malformedTrailingBytesAndCurrentCancellationKeepAllFactsAndReleasePayment():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(root+"/ledger-payment.sqlite")
        let pool=LogicalJsonOwnerBudget();let checks=LiveLedgerPaymentChecks()
        try{
            let raw=encodeStoredValue(objectValue([ValueField("body",textValue("完整"))]))+" trailing"
            database.execute("INSERT INTO audit_events(kind,payload,created_at_millis) VALUES('live_payment_fixture',?,1)",[SqlParameter.Text(raw)])
            var rejected=false
            try{database.readTransaction<Unit>{tx=>let _=contextReadMetadataMeasure(tx,"payload",
                " FROM audit_events WHERE kind='live_payment_fixture'",[],{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})}}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            database.execute("UPDATE audit_events SET payload=? WHERE kind='live_payment_fixture'",
                [SqlParameter.Text(encodeStoredValue(objectValue([ValueField("body",textValue("original"))])))])
            var cancelled=false
            try{database.readTransaction<Unit>{tx=>let _=contextReadMetadataMeasure(tx,"payload",
                " FROM audit_events WHERE kind='live_payment_fixture'",[],{bytes=>pool.acquire(bytes)},{=>
                    checks.value+=1
                    if(checks.value>1){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.ledger_cancelled","actual current check cancelled"))}
                    else{Result<Unit>.Ok(())}})}}catch(_:Exception){cancelled=true}
            @Expect(cancelled,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            @Expect(database.scalarInt("SELECT count(*) FROM audit_events WHERE kind='live_payment_fixture'"),1)
            @Expect(database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            @Expect(database.scalarInt("SELECT count(*) FROM memories"),0)
            @Expect(database.scalarInt("SELECT count(*) FROM memory_events"),0)
        }finally{database.close();remove(root,recursive:true)}
    }
}
