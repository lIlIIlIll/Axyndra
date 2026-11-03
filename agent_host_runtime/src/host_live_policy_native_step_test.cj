package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func step248Require<T>(value:Result<T>):T{
    match(value){case Result.Ok(actual)=>actual;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
// These are real fixed-file, complete original codec and Session cleanup
// controls. They do not fabricate a Source, read fact, approval or Receipt.
@Test
class LivePolicyStepMetadata248Tests {
    @TestCase
    func completeUnicodeAndNulMetadataUsesOriginalWriterAndActualFDACK():Unit{
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=step248Require(session.retainExecutionCustody());let calls=AtomicInt64(0)
        try{
            let result=session.run({actual=>
                let original=objectValue([ValueField("message",textValue("中文\u{0000}\\\"")),ValueField("n",integerValue(7))])
                let raw=encodeAgentValue(original);let writer=step248Require(actual.newWriter())
                step248Require(writer.appendBytes(0,raw.toArray(),8388608));step248Require(writer.finish(raw.size,modelPolicySha256Text(raw)))
                step248Require(actual.inspectLivePolicyWriterMetadata(writer,{=>Result<Unit>.Ok(())},{value=>
                    @Expect(encodeAgentValue(value),raw);let _=calls.fetchAdd(1)}))
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.isOk(),true);@Expect(calls.load(),1)
            @Expect(session.livePolicyTransientResourcesReleased(),true)
            @Expect(physical.close().isOk(),true)
        }finally{let _=physical.close();let _=session.close();remove(root,recursive:true)}
    }
    @TestCase
    func currentFailureAfterCompleteMetadataConsumptionKeepsPhysicalOwnerUntilACK():Unit{
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=step248Require(session.retainExecutionCustody());let consumed=AtomicBool(false)
        try{
            let result=session.run({actual=>
                let raw="{\"x\":1}";let writer=step248Require(actual.newWriter())
                step248Require(writer.appendBytes(0,raw.toArray(),8388608));step248Require(writer.finish(raw.size,modelPolicySha256Text(raw)))
                let checked=actual.inspectLivePolicyWriterMetadata(writer,{=>if(consumed.load()){
                    hostPluginResourceError<Unit>("test.current_changed","actual current changed after the complete data callback")
                }else{Result<Unit>.Ok(())}},{_=>consumed.store(true)})
                match(checked){case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result<AgentValue>.Ok(nullValue())}})
            @Expect(result.error().getOrThrow().code,"test.current_changed");@Expect(consumed.load(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(physical.close().isOk(),true)
            let after=reserveNativeDocumentPayload(8388608);after.close()
        }finally{let _=physical.close();let _=session.close();remove(root,recursive:true)}
    }
    @TestCase
    func oversizedMetadataDoesNotOpenItsVerificationFDOrRunConsumer():Unit{
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=step248Require(session.retainExecutionCustody());let calls=AtomicInt64(0)
        try{
            let result=session.run({actual=>
                let raw="\""+String.fromUtf8(Array<Byte>(16383,repeat:97))+"\"";let writer=step248Require(actual.newWriter())
                step248Require(writer.appendBytes(0,raw.toArray()[..16384],8388608))
                step248Require(writer.appendBytes(16384,raw.toArray()[16384..],8388608))
                step248Require(writer.finish(raw.size,modelPolicySha256Text(raw)))
                match(actual.inspectLivePolicyWriterMetadata(writer,{=>Result<Unit>.Ok(())},{_=>let _=calls.fetchAdd(1)})){
                    case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result<AgentValue>.Ok(nullValue())}})
            @Expect(result.error().getOrThrow().code,"plugin.live_metadata_bound");@Expect(calls.load(),0)
            @Expect(physical.close().isOk(),true)
        }finally{let _=physical.close();let _=session.close();remove(root,recursive:true)}
    }
}
