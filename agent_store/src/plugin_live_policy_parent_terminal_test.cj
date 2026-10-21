package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LiveParentTerminalCounter{var value:Int64=0}
class LiveParentTerminalFlag{var value:Bool=false}

// These controls cover raw output payment and actual SQLite metadata. They
// deliberately do not manufacture a Root, Source, approval or known Receipt.
// Actual parent completion positives belong to the real owned Host pipeline.
@Test
class PluginLivePolicyParentTerminalTests{
    @TestCase
    func FullOutputRetainsReservedFieldsUnicodeAndOriginalNumberSpelling():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(1)
        let value=objectValue([ValueField("_axyndra_context",textValue("keep this output field")),
            ValueField("request",textValue("keep this too")),ValueField("unicode",textValue("中文😀\u{0000}\n")),
            ValueField("number",JsonNode.number("1e0"))])
        let consumed=LiveParentTerminalFlag()
        try{
            withPluginLivePolicyTerminalOutputEncoding(value,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{encoded=>
                @Expect(encoded,encodeAgentValue(value));@Expect(encoded.contains("_axyndra_context"),true)
                @Expect(encoded.contains("1e0"),true);@Expect(budget.usage()[0],2);consumed.value=true})
            @Expect(consumed.value,true);@Expect(budget.usage()[0],1)
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func OriginalEightMiBOutputBoundaryDoesNotBecomeAnInputProjection():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(4194304)
        try{
            let exact=textValue(String.fromUtf8(Array<Byte>(8388606,repeat:65)))
            let consumed=LiveParentTerminalFlag()
            withPluginLivePolicyTerminalOutputEncoding(exact,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{encoded=>
                @Expect(encoded.size,8388608);@Expect(budget.usage()[0],2);consumed.value=true})
            @Expect(consumed.value,true);@Expect(budget.usage()[0],1)
            let tooLarge=textValue(String.fromUtf8(Array<Byte>(8388607,repeat:65)))
            var rejected=false;let extraConsumed=LiveParentTerminalFlag()
            try{withPluginLivePolicyTerminalOutputEncoding(tooLarge,{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{_=>extraConsumed.value=true})}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(extraConsumed.value,false);@Expect(budget.usage()[0],1)
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CancellationAndConsumerFailureReleaseOnlyTheEncodingOwner():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(1)
        let allocations=LiveParentTerminalCounter();let probes=LiveParentTerminalCounter()
        try{
            for(threshold in [Int64(1),Int64(2),Int64(3)]){
                allocations.value=0;probes.value=0;let consumed=LiveParentTerminalFlag();var rejected=false
                try{withPluginLivePolicyTerminalOutputEncoding(textValue("output"),{bytes=>
                    allocations.value++;budget.acquire(bytes)}, {=>probes.value++
                    if(probes.value>=threshold){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                        "terminal.cancelled","actual owner cancelled"))}else{Result<Unit>.Ok(())}}, {_=>consumed.value=true})}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(consumed.value,false)
                @Expect(allocations.value,if(threshold==1){0}else{1});@Expect(budget.usage()[0],1)
            }
            var callbackFailed=false
            try{withPluginLivePolicyTerminalOutputEncoding(textValue("output"),{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{_=>throw IllegalStateException("actual consumer failed")})}
            catch(_:Exception){callbackFailed=true}
            @Expect(callbackFailed,true);@Expect(budget.usage()[0],1)
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func NumericWriterFailureKeepsOriginalBehaviorAndReleasesItsOwner():Unit{
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(1)
        try{
            for(literal in ["00","-0.0.0","1e", "9223372036854775808.0.0"]){
                var originalFailed=false;var wrappedFailed=false;let consumed=LiveParentTerminalFlag()
                try{let _=encodeAgentValue(JsonNode.number(literal))}catch(_:IllegalArgumentException){originalFailed=true}
                try{withPluginLivePolicyTerminalOutputEncoding(JsonNode.number(literal),{bytes=>budget.acquire(bytes)},
                    {=>Result<Unit>.Ok(())},{_=>consumed.value=true})}catch(_:IllegalArgumentException){wrappedFailed=true}
                @Expect(originalFailed,true);@Expect(wrappedFailed,true);@Expect(consumed.value,false)
                @Expect(budget.usage()[0],1)
            }
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func EmptyRealSqliteRejectsMetadataBeforeTheContentCallback():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/terminal.sqlite")
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(1);let callbacks=LiveParentTerminalCounter()
        let digest=modelPolicySha256Text("null")
        let payload=parsePluginDocumentPayloadReference(objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
            ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
        try{
            var rejected=false
            try{db.readTransaction<Unit>{tx=>requireLivePolicyParentTerminalBlob(tx,payload,{bytes=>budget.acquire(bytes)},
                {=>callbacks.value++;Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(callbacks.value,0);@Expect(budget.usage()[0],1)
            for(table in ["artifacts","audit_events","operations","operation_receipts","items","approvals"]){
                @Expect(db.scalarInt("SELECT count(*) FROM "+table),0)}
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func ActualMetadataMutationDuringVerificationRollsBackWithoutTerminalAudit():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/terminal.sqlite")
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let held=budget.acquire(1);let callbacks=LiveParentTerminalCounter()
        let digest=modelPolicySha256Text("null")
        let payload=parsePluginDocumentPayloadReference(objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
            ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
        let metadata=encodeAgentValue(objectValue([ValueField("version",integerValue(1)),ValueField("ref",textValue("blob:sha256:"+digest)),
            ValueField("sha256",textValue(digest)),ValueField("bytes",integerValue(4)),ValueField("content_type",textValue("text/plain; charset=utf-8"))]))
        try{
            db.transaction<Unit>{tx=>tx.execute("INSERT INTO artifacts(hash,mime,size,metadata,relative_path) VALUES (?,?,4,?,?)",
                [SqlParameter.Text(digest),SqlParameter.Text("text/plain; charset=utf-8"),SqlParameter.Text(metadata),
                 SqlParameter.Text("blobs/"+digest+".txt")])}
            var rejected=false
            try{db.transaction<Unit>{tx=>requireLivePolicyParentTerminalBlob(tx,payload,{bytes=>budget.acquire(bytes)},
                {=>callbacks.value++;tx.execute("UPDATE artifacts SET metadata='{}' WHERE hash=?",[SqlParameter.Text(digest)])
                    Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(callbacks.value,1);@Expect(budget.usage()[0],1)
            db.readTransaction<Unit>{tx=>requireDocumentPayloadMetadata(tx,payload)}
            @Expect(db.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(db.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
