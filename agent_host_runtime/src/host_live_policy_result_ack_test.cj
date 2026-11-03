package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class LivePolicyAckCounter79 {
    var value: Int64 = 0
}

class UnavailableTerminalOwner292 <: OperationTerminalDataOwner {
    public func withRetainedOutput(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{Result.Ok(())}
}

// Real output files, original decoder, original shared payment and same
// physical Session. No Source, Known child or Root Receipt is fabricated.
@Test
class LivePolicyActualResultAcknowledgement292Tests {
    @TestCase
    func unsupportedOwnerDoesNotTurnUnitLeaseIntoPhysicalAcknowledgement():Unit{
        let called=LivePolicyAckCounter79()
        let lease=ToolResultPayloadLease({=>called.value+=1})
        let result=UnavailableTerminalOwner292().closeRetainedOutput(lease)
        @Expect(result.error().getOrThrow().code,"operation.terminal_output_close_unavailable")
        @Expect(called.value,0)
        lease.close();@Expect(called.value,1)
    }

    @TestCase
    func actualSessionAcknowledgementRequiresExactLeaseAndAllowsClosedSourceCleanup():Unit{
        let root=Directory.createTemp("/tmp").toString();let session=HostDocumentDataSession(HostArtifactStore(root))
        let physical=terminal250Require(session.retainExecutionCustody())
        var decoded=session.run({actual=>
            let writer=terminal250Require(actual.newWriter());let raw="\"actual decoded value\"".toArray();let hash=SHA256();hash.write(raw)
            terminal250Require(writer.appendBytes(0,raw,8388608))
            terminal250Require(writer.finish(raw.size,hostArtifactHex(hash.finish())))
            actual.readPrivateLiveToolValue(writer,{=>Result<Unit>.Ok(())})})
        try{
            @Expect(decoded.isOk(),true)
            // The old retained-context release rejects a pending Tool output;
            // the separate final-output path disposes only actual transients.
            @Expect(physical.releaseTransient().isError(),true)
            @Expect(session.releaseLivePolicyOutputTransient292().isOk(),true)
            let lease=terminal250Require(session.captureAcknowledgedLivePolicyOutputLease292())
            let currentCalls=LivePolicyAckCounter79()
            let owner=HostLivePolicyTerminalDataOwner(session,lease,nullValue(),
                {=>currentCalls.value+=1;hostPluginResourceError("test.closed_source","old Source is closed")},
                {=>currentCalls.value+=1;hostPluginResourceError("test.closed_source","old Source is closed")})
            let foreignCloses=LivePolicyAckCounter79();let foreignLease79=ToolResultPayloadLease({=>foreignCloses.value+=1})
            @Expect(owner.closeRetainedOutput(foreignLease79).isError(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),true)
            @Expect(foreignCloses.value,0);@Expect(currentCalls.value,0)
            var rawCloseFailed=false
            try{lease.close()}catch(error:HostArtifactOperationFailure){
                rawCloseFailed=error.failure.code=="plugin.live_terminal_data_owner_ack_pending"}
            @Expect(rawCloseFailed,true)
            @Expect(session.livePolicyPrivateOutputRetained(),true)
            decoded=hostPluginResourceError<AgentValue>("test.consumed","actual decoded value has been consumed")
            @Expect(owner.closeRetainedOutput(lease).isOk(),true)
            @Expect(owner.closeRetainedOutput(lease).isOk(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(physical.close().isOk(),true)
            lease.close();@Expect(currentCalls.value,0)
            let after=reserveNativeDocumentPayload(8388608);after.close()
        }finally{
            decoded=hostPluginResourceError<AgentValue>("test.discarded","actual decoded value was discarded")
            session.acknowledgeOutput();let _=physical.close();let _=session.close();remove(root,recursive:true)
        }
    }
}
