package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Real SQLite metadata/payment controls, no fabricated canonical Source,
// admission, approval, child outcome or live-family authorization.
class LiveHeaderPaymentObservation{var copied=false}

@Test
class PluginLivePolicyHeaderPaymentTests{
    @TestCase
    func allNineCopiedColumnsIncludingMalformedLargeStatesArePrepaidBeforeCopy():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/header.sqlite")
        let pool=LogicalJsonOwnerBudget(maximumCharged:16777216)
        try{
            let huge=String.fromUtf8(Array<Byte>(2097152,repeat:b'x'))+"雪"
            db.execute("CREATE TABLE live_header_payment_fixture(a TEXT,b TEXT,c TEXT,d TEXT,e TEXT,f TEXT,state TEXT,outcome TEXT,depth TEXT)")
            db.execute("INSERT INTO live_header_payment_fixture VALUES('a','b','c','d','e','f',?,?,?)",
                [SqlParameter.Text(huge),SqlParameter.Text(huge),SqlParameter.Text(huge)])
            var rejected=false;let observed=LiveHeaderPaymentObservation()
            try{db.readTransaction<Unit>{tx=>
                let rows=tx.query("SELECT length(CAST(a AS BLOB)),length(CAST(b AS BLOB)),length(CAST(c AS BLOB)),length(CAST(d AS BLOB)),length(CAST(e AS BLOB)),length(CAST(f AS BLOB)),length(CAST(state AS BLOB)),length(CAST(outcome AS BLOB)),length(CAST(depth AS BLOB)) FROM live_header_payment_fixture")
                let bytes=livePolicyLedgerCopiedHeaderBytes(rows[0])
                @Expect(bytes,6+3*huge.size)
                let paid=pool.acquire(65536)
                try{
                    paid.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
                    let _=tx.query("SELECT a,b,c,d,e,f,state,outcome,depth FROM live_header_payment_fixture")
                    observed.copied=true
                }finally{paid.close()}
            }}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(observed.copied,false)
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            @Expect(db.scalarInt("SELECT count(*) FROM operation_receipts"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM derived_operation_admissions"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM live_header_payment_fixture"),1)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func validStateOutcomeAndDepthStayInTheSameNineColumnExtentAndOriginalPool():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/header.sqlite")
        let pool=LogicalJsonOwnerBudget()
        try{db.readTransaction<Unit>{tx=>
            let lengths=tx.query("SELECT length(CAST('操作' AS BLOB)),1,1,1,1,1,length(CAST('committed' AS BLOB)),length(CAST('completed' AS BLOB)),length(CAST(1 AS BLOB))")
            let bytes=livePolicyLedgerCopiedHeaderBytes(lengths[0]);@Expect(bytes,30)
            let paid=pool.acquire(65536)
            try{
                paid.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
                let row=tx.query("SELECT '操作','b','c','d','e','f','committed','completed',1")[0]
                var measured:Int64=0;for(index in 0..row.size){measured+=row.required(index).size}
                @Expect(measured,bytes);@Expect(pool.usage()[0],1)
            }finally{paid.close()}
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }}finally{db.close();remove(root,recursive:true)}
    }
}
