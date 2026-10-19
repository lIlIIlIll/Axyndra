package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real Session and process-wide allocation pool, no fake Source or Root.
func contextUploadFixture(bytes:Int64):AgentValue{
    textValue(String.fromUtf8(Array<Byte>(bytes-2,repeat:b'a')))
}

@Test
class HostContextParameterUploadTests {
    @TestCase
    func exactOriginalContentMaximumKeepsEveryByteAndCompleteHash():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-context-upload"))
        try{
            let value=contextUploadFixture(CONTENT_PAYLOAD_MESSAGE_BYTES)
            let bytes=session.contextParameterUploadBytes(value).value().getOrThrow()
            @Expect(bytes.size,CONTENT_PAYLOAD_MESSAGE_BYTES)
            @Expect(String.fromUtf8(bytes),stringifyUnifiedJson(value))
            @Expect(modelPolicySha256Text(String.fromUtf8(bytes)),modelPolicySha256Text(stringifyUnifiedJson(value)))
        }finally{@Expect(session.close().isOk(),true)}
    }
    @TestCase
    func contentMaximumPlusOneRejectsWithoutAnExpandedCopy():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-context-upload-overflow"))
        try{
            @Expect(session.contextParameterUploadBytes(contextUploadFixture(CONTENT_PAYLOAD_MESSAGE_BYTES+1)).isError(),true)
            @Expect(session.contextParameterUploadBytes(textValue("small")).isOk(),true)
        }finally{@Expect(session.close().isOk(),true)}
    }
    @TestCase
    func ordinaryMethodKeepsItsOriginalMaximumAndRejectsFullContext():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-ordinary-upload"))
        try{
            @Expect(session.parameterUploadBytes(contextUploadFixture(ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX)).value().getOrThrow().size,
                ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX)
            @Expect(session.parameterUploadBytes(contextUploadFixture(ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX+1)).isError(),true)
            @Expect(session.parameterUploadBytes(contextUploadFixture(CONTENT_PAYLOAD_MESSAGE_BYTES)).isError(),true)
        }finally{@Expect(session.close().isOk(),true)}
    }
    @TestCase
    func actualSharedPoolExhaustionPrecedesSerializationAndCleanupReleasesEveryOwner():Unit{
        let occupied=reserveNativeDocumentPayload(1)
        occupied.ensureRetainedPeak(100663296)
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-context-upload-pool"))
        try{
            @Expect(session.contextParameterUploadBytes(contextUploadFixture(CONTENT_PAYLOAD_MESSAGE_BYTES)).error().getOrThrow().code,
                "plugin.document_query_capacity")
        }finally{@Expect(session.close().isOk(),true);occupied.close()}
        // The full original pool can now be reserved by one real owner.
        let all=reserveNativeDocumentPayload(1)
        try{all.ensureRetainedPeak(134217728)}finally{all.close()}
        let fresh=HostDocumentDataSession(HostArtifactStore("/never-opened-context-upload-retry"))
        try{@Expect(fresh.contextParameterUploadBytes(contextUploadFixture(CONTENT_PAYLOAD_MESSAGE_BYTES)).isOk(),true)}
        finally{@Expect(fresh.close().isOk(),true)}
    }
}
