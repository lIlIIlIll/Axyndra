package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real SQLite codec/accounting controls, not a Root, Receipt, successful
// canonical commit or recovery fixture. Full actual Core controls are separate.
class LiveKnownStreamCancellation {var calls:Int64=0}
@Test
class PluginLiveKnownStoredStreamTests {
    @TestCase
    func OriginalCodecAndOwnedDomWriterAreBothFullByteOracles():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/stream.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let values=[nullValue(),boolValue(false),numberValue("-0"),textValue("中文😀\u{0000}"),
            listValue([numberValue("1.50e+2"),textValue("\\\"\n")]),
            objectValue([ValueField("z",integerValue(3)),ValueField("a",textValue("whole"))])]
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                for(value in values){let raw=encodeStoredValue(value)
                    tx.execute("DELETE FROM known_cell")
                    tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                    let scanner=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})
                    let observed=scanner.complete()
                    @Expect(observed,modelPolicySha256Text(raw))
                    @Expect(observed,livePolicyInputStoredDigestStreamedOwned(value,owner,{=>Result<Unit>.Ok(())}))
                    @Expect(pool.usage()[0],1)}
            }
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0)
    }
    @TestCase
    func NearEightMiBTextCrossesEveryChunkWithoutAnotherPhysicalSlot():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/near.sqlite")
        let raw=encodeStoredValue(textValue(String.fromUtf8(Array<Byte>(8388500,repeat:65))))
        let expected=modelPolicySha256Text(raw);let pool=LogicalJsonOwnerBudget()
        let output=pool.acquire(8388608);let session=pool.acquire(65536);let registry=pool.acquire(65536)
        let owner=pool.acquire(65536);let observation=pool.acquireFixedBuffer(65536);let control=pool.acquireFixedBuffer(16384)
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                let scanner=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})
                @Expect(scanner.complete(),expected)
                @Expect(pool.usage()[0],6);@Expect(pool.usage()[1],117522432)
                var refused=false
                try{let extra=pool.acquire(65536);extra.close()}catch(_:LogicalJsonPayloadError){refused=true}
                @Expect(refused,true)}
        }finally{control.close();observation.close();owner.close();registry.close();session.close();output.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func Utf8SplitAtTheSqlChunkBoundaryMatchesTheOriginalDecoder():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/unicode.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                for(padding in [Int64(16370),Int64(16371),Int64(16372),Int64(16373)]){
                    let raw=encodeStoredValue(textValue(String.fromUtf8(Array<Byte>(padding,repeat:65))+"😀中文"))
                    tx.execute("DELETE FROM known_cell")
                    tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                    @Expect(LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,
                        {=>Result<Unit>.Ok(())}).complete(),modelPolicySha256Text(raw))
                    @Expect(decodeStoredValue(raw).text.size>padding,true)}
            }
        }finally{owner.close();db.close();remove(root,recursive:true)}
    }
    @TestCase
    func EofDuplicateDepthCountAndNumberFailuresAgreeWithOriginalCodec():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/invalid.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                for(raw in ["s1:an","o1:21:kn1:kn","l7:1000001","d1:x","s2:a"]){
                    tx.execute("DELETE FROM known_cell")
                    tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                    var original=false;var streamed=false
                    try{let _=decodeStoredValue(raw)}catch(_:Exception){original=true}
                    try{let _=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,
                        {=>Result<Unit>.Ok(())}).complete()}catch(_:Exception){streamed=true}
                    @Expect(streamed,original);@Expect(streamed,true)}
                var deep="n";for(_ in 0..66){deep="l1:1"+deep}
                tx.execute("DELETE FROM known_cell")
                tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(deep)])
                var originalDeep=false;var streamedDeep=false
                try{let _=decodeStoredValue(deep)}catch(_:Exception){originalDeep=true}
                try{let _=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,
                    {=>Result<Unit>.Ok(())}).complete()}catch(_:Exception){streamedDeep=true}
                @Expect(streamedDeep,originalDeep);@Expect(streamedDeep,true)
                tx.execute("DELETE FROM known_cell")
                tx.execute("INSERT INTO known_cell(payload) VALUES(CAST(x'73343AF0808080' AS TEXT))")
                var invalidUtf8=false
                try{let _=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,
                    {=>Result<Unit>.Ok(())}).complete()}catch(_:Exception){invalidUtf8=true}
                @Expect(invalidUtf8,true);@Expect(pool.usage()[0],1)}
        }finally{owner.close();db.close();remove(root,recursive:true)}
    }
    @TestCase
    func LargeIgnoredResultStillHasFullGrammarAndItsActualHeader():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/header.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let raw=encodeStoredThreadContent(ThreadItemContent.ToolResult(CanonicalToolCallId("call"),
            OperationId("parent"),"receipt-parent",textValue("whole body"),false))
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(raw)])
                let scanner=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,{=>Result<Unit>.Ok(())})
                @Expect(scanner.complete(),modelPolicySha256Text(raw))
                let header=scanner.header()
                @Expect(httpIntentText(header,"call_id"),"call")
                @Expect(httpIntentText(header,"operation_id"),"parent")
                @Expect(httpIntentText(header,"receipt_id"),"receipt-parent")
                @Expect(header.field("result").isNone(),true)}
        }finally{owner.close();db.close();remove(root,recursive:true)}
    }
    @TestCase
    func CancellationAndThrowNeverCloseOrRefundTheBorrowedOwner():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/cancel.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536);let state=LiveKnownStreamCancellation()
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE known_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO known_cell(payload) VALUES(?)",[SqlParameter.Text(encodeStoredValue(textValue("complete")))])
                var refused=false
                try{let _=LiveKnownStoredStream(tx,"payload"," FROM known_cell",[],owner,1048576,{=>
                    state.calls++;if(state.calls>=3){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"test.cancelled","stop"))}
                    else{Result<Unit>.Ok(())}}).complete()}catch(_:Exception){refused=true}
                @Expect(refused,true);@Expect(pool.usage()[0],1)
                @Expect(pool.usage()[1],16777216)}
        }finally{owner.close();db.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0)
    }
}
