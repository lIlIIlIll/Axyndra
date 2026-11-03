package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

func terminal250Require<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
}

// Actual files, resultReservation and allocation lease only. No Root/Source,
// operation, approval, audit pin or known completion is fabricated here.
@Test
class LivePolicyFinalAllocation250Tests {
    @TestCase
    func originalEightMiBToolDataUsesActualLeaseAndKeepsContextLimit():Unit{
        let root=Directory.createTemp("/tmp").toString();let artifacts=HostArtifactStore(root)
        let session=artifacts.documentDataSession();let physical=terminal250Require(session.retainExecutionCustody())
        var decoded=session.run({owner=>
            let writer=terminal250Require(owner.newWriter());let hash=SHA256()
            let quoteBytes79="\"".toArray();terminal250Require(writer.appendBytes(0,quoteBytes79,8388608));hash.write(quoteBytes79)
            let chunk=Array<Byte>(16384,repeat:97);var offset:Int64=1
            while(offset<8387583){let size=min(16384,8387583-offset);let bytes=chunk[..size]
                terminal250Require(writer.appendBytes(offset,bytes,8388608));hash.write(bytes);offset+=size}
            terminal250Require(writer.appendBytes(offset,quoteBytes79,8388608));hash.write(quoteBytes79)
            terminal250Require(writer.finish(8387584,hostArtifactHex(hash.finish())))
            @Expect(owner.readPrivateContextValue(writer,8388608,{=>Result<Unit>.Ok(())}).isError(),true)
            owner.readPrivateLiveToolValue(writer,{=>Result<Unit>.Ok(())})})
        try{
            @Expect(decoded.isOk(),true)
            @Expect(decoded.value().getOrThrow().asString().size,8387582)
            @Expect(physical.releaseTransient().isError(),true)
            @Expect(session.releaseLivePolicyOutputTransient292().isOk(),true)
            let lease=terminal250Require(session.captureAcknowledgedLivePolicyOutputLease292())
            let owner=HostAcknowledgedLivePolicyTerminalDataOwner294(session,lease,nullValue(),
                {=>Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})
            @Expect(session.captureAcknowledgedLivePolicyOutputLease292().isError(),true)
            var exhausted=false
            try{let extra=reserveNativeDocumentPayload(8388608);extra.close()}catch(_:LogicalJsonPayloadError){exhausted=true}
            @Expect(exhausted,true)
            // Drop the actual decoded reference before the real consumer ACK.
            decoded=hostPluginResourceError<AgentValue>("test.consumed","data was consumed")
            @Expect(owner.closeRetainedOutput(lease).isOk(),true)
            lease.close()
            let after=reserveNativeDocumentPayload(8388608);after.close()
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(physical.close().isOk(),true)
        }finally{
            decoded=hostPluginResourceError<AgentValue>("test.discarded","data was discarded")
            session.acknowledgeOutput();let _=physical.close();let _=session.close();remove(root,recursive:true)
        }
    }

    @TestCase
    func exactEightMiBJSONStillRejectsOversizedOriginalStoredValueAndRefundsItsOwner():Unit{
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=terminal250Require(session.retainExecutionCustody())
        try{
            let rejected=session.run({owner=>
                let writer=terminal250Require(owner.newWriter());let hash=SHA256()
                let quoteBytes79="\"".toArray();terminal250Require(writer.appendBytes(0,quoteBytes79,8388608));hash.write(quoteBytes79)
                let chunk=Array<Byte>(16384,repeat:97);var offset:Int64=1
                while(offset<8388607){let size=min(16384,8388607-offset);let raw=chunk[..size]
                    terminal250Require(writer.appendBytes(offset,raw,8388608));hash.write(raw);offset+=size}
                terminal250Require(writer.appendBytes(offset,quoteBytes79,8388608));hash.write(quoteBytes79)
                terminal250Require(writer.finish(8388608,hostArtifactHex(hash.finish())))
                owner.readPrivateLiveToolValue(writer,{=>Result<Unit>.Ok(())})})
            @Expect(rejected.error().getOrThrow().code,"context.document_result_codec")
            @Expect(session.captureLivePolicyOutputLease().isError(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(physical.close().isOk(),true)
            let after=reserveNativeDocumentPayload(8388608);after.close()
        }finally{session.acknowledgeOutput();let _=physical.close();let _=session.close();remove(root,recursive:true)}
    }
    @TestCase
    func outputLeaseCannotBeCapturedFromInertOrUnpaidSessionResult():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-terminal250"))
        try{
            @Expect(session.captureLivePolicyOutputLease().isError(),true)
            let physical=terminal250Require(session.retainExecutionCustody())
            @Expect(session.run({_=>Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(session.captureLivePolicyOutputLease().isError(),true)
            @Expect(physical.close().isOk(),true)
        }finally{let _=session.close()}
    }
}
