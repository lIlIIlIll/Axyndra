package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real SQLite cells and pool controls only. No Source, Root, successful
// Receipt or Host fixed-file proof is seeded or claimed by these controls.
class LiveOwnedCellChecks {var calls:Int64=0}
@Test
class PluginLivePolicyOwnedCellPrefixTests {
    @TestCase
    func FixedBuffersStayChargedWhileSmallCompleteCellUsesTheCallerOwner():Unit {
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/owned.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608)
        let session=pool.acquire(65536);let registry=pool.acquire(65536);let owner=pool.acquire(65536)
        let observation=pool.acquireFixedBuffer(65536);let control=pool.acquireFixedBuffer(16384)
        let raw=encodeStoredValue(textValue("complete 中文😀\u{0000}"))
        try {
            database.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE owned_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO owned_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                let cell=contextReadMetadataMeasureOwned(tx,"payload"," FROM owned_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})
                @Expect(cell.bytes,raw.size);@Expect(cell.nodes,1)
                @Expect(pool.usage()[0],6);@Expect(pool.usage()[1],117522432)
                // The original extra physical reservation genuinely cannot
                // coexist here. The borrowed scan never refunds any owner.
                var refused=false
                try{let extra=pool.acquire(65536);extra.close()}catch(_:LogicalJsonPayloadError){refused=true}
                @Expect(refused,true);@Expect(pool.usage()[1],117522432)}
        }finally{control.close();observation.close();owner.close();registry.close();session.close();output.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func NestedBorrowedCellInvoicesIncludeTheStillLiveOuterRawAndDom():Unit {
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/nested.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let raw=encodeStoredValue(textValue(String.fromUtf8(Array<Byte>(1048576,repeat:65))))
        try {
            database.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE owned_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO owned_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                let cell=contextReadMetadataMeasureOwned(tx,"payload"," FROM owned_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})
                let retained=journalStreamAdd(1048576,contextReadMetadataPeak(cell.bytes,cell.nodes))
                withLivePolicyStoredValueOwned(tx,"payload"," FROM owned_cell",[],{bytes=>pool.acquire(bytes)},
                    {=>Result<Unit>.Ok(())},owner,1048576,{outer=>
                        withLivePolicyStoredValueOwned(tx,"payload"," FROM owned_cell",[],{bytes=>pool.acquire(bytes)},
                            {=>Result<Unit>.Ok(())},owner,retained,{inner=>
                                @Expect(inner,outer);@Expect(inner,raw)
                                @Expect(pool.usage()[0],1)
                                @Expect(pool.usage()[1]>=journalStreamAdd(retained,contextReadMetadataPeak(cell.bytes,cell.nodes)),true)})})
                @Expect(pool.usage()[0],1)}
        }finally{owner.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func OriginalEofDuplicateAndUtf8FailuresCannotAcknowledgeTheBorrower():Unit {
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/invalid.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        try {
            database.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE owned_cell(payload TEXT NOT NULL)")
                for(raw in ["s1:an","o1:21:kn1:kn"]){
                    tx.execute("DELETE FROM owned_cell")
                    tx.execute("INSERT INTO owned_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                    var rejected=false
                    try{let _=contextReadMetadataMeasureOwned(tx,"payload"," FROM owned_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})}
                    catch(_:Exception){rejected=true}
                    @Expect(rejected,true);@Expect(pool.usage()[0],1)}
                tx.execute("DELETE FROM owned_cell")
                tx.execute("INSERT INTO owned_cell(payload) VALUES(CAST(x'73313AFF' AS TEXT))")
                var utf8Rejected=false
                try{let _=contextReadMetadataMeasureOwned(tx,"payload"," FROM owned_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})}
                catch(_:Exception){utf8Rejected=true}
                @Expect(utf8Rejected,true);@Expect(pool.usage()[0],1)}
        }finally{owner.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func MidScanCancellationLeavesCallerAndAllDatabaseCellsOwned():Unit {
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/cancel.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536);let checks=LiveOwnedCellChecks()
        let raw=encodeStoredValue(textValue("original complete"))
        try {
            database.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE owned_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO owned_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                var cancelled=false
                try{let _=contextReadMetadataMeasureOwned(tx,"payload"," FROM owned_cell",[],owner,1048576,{=>
                    checks.calls++
                    if(checks.calls>1){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"cell.cancelled","actual atomic cancellation"))}
                    else{Result<Unit>.Ok(())}})}catch(_:Exception){cancelled=true}
                @Expect(cancelled,true);@Expect(pool.usage()[0],1)
                @Expect(tx.query("SELECT payload FROM owned_cell")[0].required(0),raw)}
        }finally{owner.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func RawNumberSpellingAndFieldOrderMatchTheOriginalStoredWriter():Unit {
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/original.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let value=objectValue([ValueField("z",JsonNode.number("1e0")),ValueField("a",textValue("中文"))])
        let raw=encodeStoredValue(value)
        try {
            database.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE owned_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO owned_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                withContextReadMetadataCellOwned(tx,"SELECT length(CAST(payload AS BLOB)) FROM owned_cell","SELECT payload FROM owned_cell",[],
                    owner,1048576,{=>Result<Unit>.Ok(())},{actual,meter=>
                        @Expect(actual,raw);@Expect(meter.nodeCount(),3)
                        let decoded=decodeStoredValue(actual)
                        @Expect(decoded.fields[0].name,"z");@Expect(decoded.field("z").getOrThrow().asNumberText(),"1e0")
                        @Expect(encodeStoredValue(decoded),raw)})
                @Expect(pool.usage()[0],1)}
        }finally{owner.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func EmptyPrefixUnitUsesOneOwnerAndCanShareBoundedMetadataWithoutGrant():Unit {
        let fixture=LivePolicyInputAbsentFactsFixture();let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608)
        let session=pool.acquire(65536);let registry=pool.acquire(65536);let fixed=pool.acquireFixedBuffer(65536)
        let checks=LiveOwnedCellChecks()
        let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(fixture.parent.value)),ValueField("through_sequence",integerValue(0)),ValueField("tip",nullValue())])
        try {
            fixture.database.readTransaction<Unit>{tx=>
                withPluginLivePolicyReceiptPrefixOwned(tx,fixture.parent,fixture.run,"live-input-call",fixture.binding(),0,reference,
                    {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},{owner,retained=>
                        checks.calls++;owner.ensureRetainedPeak(journalStreamAdd(retained,1048576))
                        @Expect(retained,1048576);@Expect(pool.usage()[0],5)
                        @Expect(pool.usage()[1],117506048)})
                @Expect(checks.calls,1);@Expect(pool.usage()[0],4)}
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM operations"),0)
        }finally{fixed.close();registry.close();session.close();output.close();fixture.database.close();remove(fixture.root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
