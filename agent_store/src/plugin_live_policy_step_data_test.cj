package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class LiveStepMetadataCounter{var value:Int64=0}
private func liveStepTestPayload():PluginDocumentPayloadReference{
    let digest=modelPolicySha256Text("null")
    parsePluginDocumentPayloadReference(objectValue([
        ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
        ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
}
private func liveStepTestSeed(tx:SqliteTransaction,payload:PluginDocumentPayloadReference):Unit{
    let metadata=encodeAgentValue(objectValue([ValueField("version",integerValue(1)),ValueField("ref",textValue("blob:sha256:"+payload.digest)),
        ValueField("sha256",textValue(payload.digest)),ValueField("bytes",integerValue(4)),ValueField("content_type",textValue("text/plain; charset=utf-8"))]))
    tx.execute("INSERT INTO artifacts(hash,mime,size,metadata,relative_path) VALUES (?,?,4,?,?)",
        [SqlParameter.Text(payload.digest),SqlParameter.Text("text/plain; charset=utf-8"),SqlParameter.Text(metadata),
            SqlParameter.Text("blobs/"+payload.digest+".txt")])
}

// Real SQLite cells and original pool owners. These tests do not construct a
// Root, approval, handoff, child Receipt or an execution permission.
@Test
class PluginLivePolicyStepMetadataTests{
    @TestCase
    func MissingActualMetadataRejectsBeforeCopyAllocation():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/step.sqlite")
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let counter=LiveStepMetadataCounter()
        try{
            var rejected=false
            try{db.readTransaction<Unit>{tx=>livePolicyStepPayloadMetadata(tx,liveStepTestPayload(),
                {bytes=>counter.value++;budget.acquire(bytes)},{=>Result<Unit>.Ok(())})}}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(counter.value,0);@Expect(budget.usage()[0],1)
            for(table in ["artifacts","audit_events","operations","operation_receipts","items"]){
                @Expect(db.scalarInt("SELECT count(*) FROM "+table),0)}
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func OriginalActualMetadataPassesAndScopeDoesNotReleaseOtherOwner():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/step.sqlite")
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let counter=LiveStepMetadataCounter();let payload=liveStepTestPayload()
        try{
            db.transaction<Unit>{tx=>liveStepTestSeed(tx,payload)}
            db.readTransaction<Unit>{tx=>livePolicyStepPayloadMetadata(tx,payload,
                {bytes=>counter.value++;budget.acquire(bytes)},{=>Result<Unit>.Ok(())})}
            @Expect(counter.value,1);@Expect(budget.usage()[0],1)
            @Expect(db.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func EveryFreshMetadataExtentPrecedesCopyAndMutationRollsBack():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/step.sqlite")
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let counter=LiveStepMetadataCounter();let payload=liveStepTestPayload()
        try{
            db.transaction<Unit>{tx=>liveStepTestSeed(tx,payload)}
            for(column in ["mime","metadata","relative_path"]){
                let maximum=if(column=="mime"){128}else if(column=="metadata"){4096}else{256}
                let oversized=String.fromUtf8(Array<Byte>(maximum+1,repeat:65));counter.value=0;var rejected=false
                try{db.transaction<Unit>{tx=>
                    tx.execute("UPDATE artifacts SET "+column+"=? WHERE hash=?",[SqlParameter.Text(oversized),SqlParameter.Text(payload.digest)])
                    livePolicyStepPayloadMetadata(tx,payload,{bytes=>counter.value++;budget.acquire(bytes)},{=>Result<Unit>.Ok(())})}}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(counter.value,0);@Expect(budget.usage()[0],1)
                db.readTransaction<Unit>{tx=>requireDocumentPayloadMetadata(tx,payload)}
            }
            @Expect(db.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CancelBeforeLookupAndThrowAfterPaidCopyRetainOriginalOwners():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/step.sqlite")
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let allocations=LiveStepMetadataCounter();let checks=LiveStepMetadataCounter()
        let payload=liveStepTestPayload()
        try{
            db.transaction<Unit>{tx=>liveStepTestSeed(tx,payload)}
            var cancelled=false
            try{db.readTransaction<Unit>{tx=>livePolicyStepPayloadMetadata(tx,payload,{bytes=>allocations.value++;budget.acquire(bytes)},
                {=>Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"step.cancelled","before actual lookup"))})}}
            catch(_:Exception){cancelled=true}
            @Expect(cancelled,true);@Expect(allocations.value,0);@Expect(budget.usage()[0],1)
            var rejected=false
            try{db.readTransaction<Unit>{tx=>livePolicyStepPayloadMetadata(tx,payload,{bytes=>allocations.value++;budget.acquire(bytes)},
                {=>checks.value++;if(checks.value==2){throw IllegalStateException("actual post-copy guard failure")};Result<Unit>.Ok(())})}}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(checks.value,2);@Expect(allocations.value,1);@Expect(budget.usage()[0],1)
            @Expect(db.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
