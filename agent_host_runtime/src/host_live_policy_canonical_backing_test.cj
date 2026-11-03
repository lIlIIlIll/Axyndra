package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

@Test
class LivePolicyActualCanonicalBacking301Tests {
    @TestCase
    func SameActualResultBackingRemainsPaidAfterPhysicalAcknowledgement():Unit{
        let pressure=reserveNativeDocumentPayload(8388608)
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=terminal250Require(session.retainExecutionCustody())
        var decoded=session.run({actual=>
            let writer=terminal250Require(actual.newWriter());let hash=SHA256()
            terminal250Require(writer.appendBytes(0,[b'"'],8388608));hash.write([b'"'])
            let chunk=Array<Byte>(16384,repeat:b'x');var at:Int64=1
            for(_ in 0..192){terminal250Require(writer.appendBytes(at,chunk,8388608));hash.write(chunk);at+=chunk.size}
            terminal250Require(writer.appendBytes(at,[b'"'],8388608));hash.write([b'"'])
            terminal250Require(writer.finish(at+1,hostArtifactHex(hash.finish())))
            actual.readPrivateLiveToolValue(writer,{=>Result<Unit>.Ok(())})})
        var backing:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
        try{
            @Expect(decoded.isOk(),true)
            @Expect(session.releaseLivePolicyOutputTransient292().isOk(),true)
            let lease=terminal250Require(session.captureAcknowledgedLivePolicyOutputLease292())
            let owner=HostAcknowledgedLivePolicyTerminalDataOwner294(session,lease,nullValue(),
                {=>Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})
            let foreignLease79=ToolResultPayloadLease({=>()})
            @Expect(owner.retainCanonicalBacking(foreignLease79).isError(),true)
            backing=Some(terminal250Require(owner.retainCanonicalBacking(lease)))
            // A real canonical alias may keep the original decoded value.
            // This test drops its local alias before SAME typed physical ACK.
            decoded=hostPluginResourceError<AgentValue>("test.consumed","original output was consumed")
            @Expect(owner.closeRetainedOutput(lease).isOk(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(owner.retainCanonicalBacking(lease).isError(),true)
            @Expect(physical.close().isOk(),true)
            var stillPaid=false
            try{let extra=reserveNativeDocumentPayload(8388608);extra.close()}
            catch(_:LogicalJsonPayloadError){stillPaid=true}
            @Expect(stillPaid,true)
            backing.getOrThrow().close();backing=None<LogicalJsonOwnerReservation>
            let after=reserveNativeDocumentPayload(8388608);after.close()
            lease.close();foreignLease79.close()
        }finally{
            decoded=hostPluginResourceError<AgentValue>("test.discarded","original output was discarded")
            match(backing){case Some(value)=>value.close();case None=>()}
            session.acknowledgeOutput();let _=physical.close();let _=session.close()
            pressure.close();remove(root,recursive:true)
        }
    }
}
