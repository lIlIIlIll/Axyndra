package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LiveTerminalOwnedBlobCounter {var value:Int64=0}
class LiveTerminalOwnedBlobFixture {
    let root:String=Directory.createTemp("/tmp").toString()
    let database:SqliteDatabase
    let digest:String=modelPolicySha256Text("null")
    let payload:PluginDocumentPayloadReference
    init(){
        database=SqliteDatabase(root+"/terminal-owned.sqlite")
        payload=parsePluginDocumentPayloadReference(objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
            ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
            ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
        let metadata=encodeAgentValue(objectValue([ValueField("version",integerValue(1)),
            ValueField("ref",textValue("blob:sha256:"+digest)),ValueField("sha256",textValue(digest)),
            ValueField("bytes",integerValue(4)),ValueField("content_type",textValue("text/plain; charset=utf-8"))]))
        database.transaction<Unit>{tx=>tx.execute("INSERT INTO artifacts(hash,mime,size,metadata,relative_path) VALUES (?,?,4,?,?)",
            [SqlParameter.Text(digest),SqlParameter.Text("text/plain; charset=utf-8"),SqlParameter.Text(metadata),
             SqlParameter.Text("blobs/"+digest+".txt")])}
    }
    func close():Unit {database.close();remove(root,recursive:true)}
}

// Actual SQLite and original pool accounting controls. The 64 MiB held
// reservation exercises simultaneous payment, not an actual Host output.
// Callbacks below do not claim a real file descriptor, Root, Source or ACK.
@Test
class PluginLivePolicyParentTerminalOwnedBlobTests {
    @TestCase
    func OriginalExtraOwnerIsRefusedButCompleteBlobMetadataBorrowsTheStillLivePrefix():Unit {
        let fixture=LiveTerminalOwnedBlobFixture();let pool=LogicalJsonOwnerBudget()
        let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let registry=pool.acquire(65536);let prefix=pool.acquire(65536)
        let observation=pool.acquireFixedBuffer(65536);let control=pool.acquireFixedBuffer(16384)
        let callbacks=LiveTerminalOwnedBlobCounter()
        try {
            var refused=false
            try{fixture.database.readTransaction<Unit>{tx=>requireLivePolicyParentTerminalBlob(tx,fixture.payload,
                {bytes=>pool.acquire(bytes)},{=>callbacks.value++;Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}}
            catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused,true);@Expect(callbacks.value,0)
            @Expect(pool.usage()[0],6);@Expect(pool.usage()[1],117522432)
            fixture.database.readTransaction<Unit>{tx=>requireLivePolicyParentTerminalBlobOwned(tx,fixture.payload,
                prefix,1048576,{=>callbacks.value++;Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}
            @Expect(callbacks.value,1);@Expect(pool.usage()[0],6);@Expect(pool.usage()[1],117522432)
            for(table in ["audit_events","operation_receipts","operations","items","approvals"]){
                @Expect(fixture.database.scalarInt("SELECT count(*) FROM "+table),0)}
        }finally{control.close();observation.close();prefix.close();registry.close();session.close();output.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func MetadataMutationInTheOwnedCallbackRollsBackWithoutClosingTheBorrower():Unit {
        let fixture=LiveTerminalOwnedBlobFixture();let pool=LogicalJsonOwnerBudget();let prefix=pool.acquire(65536)
        let callbacks=LiveTerminalOwnedBlobCounter()
        try {
            var rejected=false
            try{fixture.database.transaction<Unit>{tx=>requireLivePolicyParentTerminalBlobOwned(tx,fixture.payload,
                prefix,1048576,{=>callbacks.value++
                    tx.execute("UPDATE artifacts SET metadata='{}' WHERE hash=?",[SqlParameter.Text(fixture.digest)])
                    Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(callbacks.value,1);@Expect(pool.usage()[0],1)
            fixture.database.readTransaction<Unit>{tx=>requireDocumentPayloadMetadata(tx,fixture.payload)}
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{prefix.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func CancelledVerificationAndMissingRetainedInvoiceCannotRefundTheActualOwner():Unit {
        let fixture=LiveTerminalOwnedBlobFixture();let pool=LogicalJsonOwnerBudget();let prefix=pool.acquire(65536)
        let callbacks=LiveTerminalOwnedBlobCounter()
        try {
            for(retained in [Int64(0),Int64(1048576)]){
                var rejected=false
                try{fixture.database.readTransaction<Unit>{tx=>requireLivePolicyParentTerminalBlobOwned(tx,fixture.payload,
                    prefix,retained,{=>callbacks.value++;Result<Unit>.Ok(())},{=>Result<Unit>.Err(
                        AgentError(AgentErrorKind.Cancelled,"terminal.cancelled","actual atomic cancellation"))})}}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(callbacks.value,0);@Expect(pool.usage()[0],1)}
            fixture.database.readTransaction<Unit>{tx=>requireDocumentPayloadMetadata(tx,fixture.payload)}
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM audit_events"),0)
        }finally{prefix.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
