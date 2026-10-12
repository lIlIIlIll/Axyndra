package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Real original Session/file/decoder/metadata/physical close, not an
// execution/Source/Receipt or fake pending publication fixture.
@Test
class LivePolicyActualPendingBacking315Tests {
    @TestCase
    func OriginalCapturedMetadataBackingSurvivesOriginalPhysicalClose():Unit{
        let pressure=reserveNativeDocumentPayload(8388608)
        let root=Directory.createTemp("/tmp").toString()
        let session=HostDocumentDataSession(HostArtifactStore(root))
        var retained:?HostLivePolicySessionCustody=None<HostLivePolicySessionCustody>
        var backing:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
        try{
            @Expect(session.retainLivePolicyPendingPreparedBacking315(8192).isError(),true)
            let raw="{\"schema\":\"test-metadata\",\"kind\":\"effect\"}".toArray()
            retained=Some(terminal250Require(hostRunLivePolicyPaidSession312(session,{actual=>
                let writer=terminal250Require(actual.newWriter())
                terminal250Require(writer.appendBytes(0,raw,16384))
                terminal250Require(writer.finish(raw.size,modelPolicySha256(raw)))
                Result<HostServiceArtifactWriter>.Ok(writer)},16384,{=>Result<Unit>.Ok(())})))
            let actual=retained.getOrThrow()
            @Expect(actual.retainPendingPreparedBacking315(8192).isError(),true)
            @Expect(actual.capturePaidMetadata({value=>let _=value;Result<Unit>.Ok(())}).isOk(),true)
            @Expect(actual.retainPendingPreparedBacking315(8191).isError(),true)
            backing=Some(terminal250Require(actual.retainPendingPreparedBacking315(8192)))
            @Expect(actual.close().isOk(),true)
            @Expect(session.retainLivePolicyPendingPreparedBacking315(8192).isError(),true)
            var paid=false
            try{let other=reserveNativeDocumentPayload(8388608);other.close()}
            catch(_:LogicalJsonPayloadError){paid=true}
            @Expect(paid,true)
            // Test retained no metadata/Prepared aliases. Production Tools
            // must clear its actual mutable whole holder before this ACK.
            backing.getOrThrow().close();backing=None<LogicalJsonOwnerReservation>
            let after=reserveNativeDocumentPayload(8388608);after.close()
        }finally{
            match(retained){case Some(value)=>let _=value.close();case None=>()}
            retained=None<HostLivePolicySessionCustody>
            match(backing){case Some(value)=>value.close();case None=>()}
            backing=None<LogicalJsonOwnerReservation>
            let _=session.close();pressure.close();remove(root,recursive:true)
        }
    }
}
