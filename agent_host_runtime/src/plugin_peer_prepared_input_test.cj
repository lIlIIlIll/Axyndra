package agent_host_runtime

import agent_domain.*
import agent_store.*
import agent_extension_runtime.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class PeerPreparedInputFixture111 {
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    let original:LogicalJsonOwnerReservation
    init(){
        root=Directory.createTemp("/tmp").toString()
        database=SqliteDatabase(root+"/state/state.sqlite")
        artifacts=HostArtifactStore(root+"/state",database:Some(database))
        original=reserveNativeDocumentPayload(65536)
    }
    func allocate(bytes:Int64):LogicalJsonOwnerReservation {
        let child=original.deriveRetainedLease()
        try{child.ensureRetainedPeak(max(bytes,1048576));child}
        catch(error:Exception){child.close();throw error}
    }
    func close():Unit{original.close();database.close();remove(root,recursive:true)}
}
private func peerPreparedInputDescription111(input:AgentValue):AgentValue {
    let encoded=encodeAgentValue(input);let digest=modelPolicySha256Text(encoded)
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(encoded.size)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])
}

// Real shared-pool child loans and actual private writer/verified FD/cleanup.
// These do not claim installed Root, read approval, or child-Run execution.
@Test
class PeerPreparedInput111Tests {
    @TestCase
    func originalLargeEscapedInputCrossesPrivateFdUnchangedAndLeavesNoTemporary():Unit {
        let f=PeerPreparedInputFixture111();let session=f.artifacts.documentDataSession()
        let body=String.fromUtf8(Array<UInt8>(131072,repeat:0))+"終"
        let value=objectValue([ValueField("op",textValue("send")),ValueField("message",textValue(body)),
            ValueField("to",textValue("member")),ValueField("replyTo",textValue("original"))])
        let description=peerPreparedInputDescription111(value);let calls=AtomicInt64(0)
        try{
            @Expect(encodeAgentValue(description).size<16384)
            @Expect(encodeAgentValue(value).size>65536)
            let result=session.run({actual=>actual.withPreparedBusinessInput111(value,description,{bytes=>f.allocate(bytes)},
                {=>Result<Unit>.Ok(())},{read=>
                    @Expect(canonicalAgentValue(read),canonicalAgentValue(value))
                    @Expect(read.field("message").getOrThrow().text,body)
                    calls.fetchAdd(1);Result<AgentValue>.Ok(nullValue())})})
            @Expect(result.isOk());@Expect(calls.load(),1)
            @Expect(session.collect());@Expect(Directory.readFrom(f.root+"/state/blobs").size,0)
        }finally{let _=session.close();f.close()}
    }
    @TestCase
    func changedCompleteIdentityAndCancellationNeverInvokeTheDataConsumer():Unit {
        for(cancel in [false,true]){
            let f=PeerPreparedInputFixture111();let session=f.artifacts.documentDataSession()
            let value=objectValue([ValueField("message",textValue(String.fromUtf8(Array<UInt8>(131072,repeat:65))))])
            let description=peerPreparedInputDescription111(value);let calls=AtomicInt64(0);let checks=AtomicInt64(0)
            if(!cancel){let digest=modelPolicySha256Text("another complete input")
                description.put("sha256",textValue(digest));description.put("artifact_ref",textValue("blob:sha256:"+digest))}
            try{
                let result=session.run({actual=>actual.withPreparedBusinessInput111(value,description,{bytes=>f.allocate(bytes)},
                    {=>if(cancel && checks.fetchAdd(1)>=5){return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                        "peer.test_cancelled","actual data owner cancelled"))};Result<Unit>.Ok(())},
                    {_=>calls.fetchAdd(1);Result<AgentValue>.Ok(nullValue())})})
                @Expect(result.isError());@Expect(calls.load(),0)
                @Expect(session.collect());@Expect(Directory.readFrom(f.root+"/state/blobs").size,0)
            }finally{let _=session.close();f.close()}
        }
    }
}
