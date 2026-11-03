package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ClaimedWindowReadProof <: PluginDocumentPayloadReadProof {
    public prop threadId:ThreadId{get(){ThreadId("claimed-thread")}}
    public prop runId:RunId{get(){RunId("claimed-run")}}
    public prop operationId:OperationId{get(){OperationId("claimed-operation")}}
    public prop laneId:LaneId{get(){LaneId("main")}}
    public prop key:String{get(){"claimed-document"}}
    public prop revision:Int64{get(){1}}
    public prop bytes:Int64{get(){1}}
    public func plan():NormalizedOperationPlan{throw IllegalStateException("descriptive interface is not an actual Store proof")}
}
class ClaimedWindowCommitProof <: PluginDocumentPayloadCommitProof {
    private let operation:OperationId
    init(operation:OperationId){this.operation=operation}
    public prop runId:RunId{get(){RunId("actual-run")}}
    public prop parentOperationId:OperationId{get(){OperationId("actual-parent")}}
    public prop operationId:OperationId{get(){operation}}
    public func payload():AgentValue{objectValue([])}
}
func hostWindowOwnerTestReference():PluginDocumentPayloadReference{
    let digest=modelPolicySha256Text("{}")
    parsePluginDocumentPayloadReference(objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(2)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
}

@Test
class HostDocumentWindowOwnerTests {
    @TestCase
    func claimedReadInterfaceCannotOpenWriterOrPublishAndOwnerStaysOneShot():Unit{
        let invokes=AtomicInt64(0);let writers=AtomicInt64(0);let publications=AtomicInt64(0)
        let reader=HostDocumentPayloadReader({materializer=>let _=invokes.fetchAdd(1);materializer.materialize(ClaimedWindowReadProof())},
            {=>let _=writers.fetchAdd(1);hostPluginResourceError<HostServiceArtifactWriter>("test.writer_opened","unexpected writer")},
            {_,_=>let _=publications.fetchAdd(1);hostPluginResourceError<AgentValue>("test.publication","unexpected publication")},
            {=>Result<Unit>.Ok(())})
        try{
            let first=reader.read();@Expect(first.error().getOrThrow().code,"plugin.document_payload_proof_invalid")
            @Expect(reader.read().error().getOrThrow().code,"plugin.document_payload_reader_closed")
            @Expect(invokes.load(),1);@Expect(writers.load(),0);@Expect(publications.load(),0)
        }finally{@Expect(reader.close().isOk(),true)}
    }
    @TestCase
    func callbackOutsideReadWindowCannotSelectOrPayAnyClaimedPayload():Unit{
        let invokes=AtomicInt64(0)
        let reader=HostDocumentPayloadReader({_=>let _=invokes.fetchAdd(1);Result<AgentValue>.Ok(nullValue())},
            {=>hostPluginResourceError<HostServiceArtifactWriter>("test.writer_opened","unexpected writer")},
            {_,_=>Result<AgentValue>.Ok(nullValue())},{=>Result<Unit>.Ok(())})
        try{
            @Expect(reader.materialize(ClaimedWindowReadProof()).error().getOrThrow().code,"plugin.document_payload_window_closed")
            @Expect(invokes.load(),0);@Expect(reader.read().isOk(),true)
            @Expect(reader.materialize(ClaimedWindowReadProof()).error().getOrThrow().code,"plugin.document_payload_window_closed")
        }finally{@Expect(reader.close().isOk(),true)}
    }
    @TestCase
    func matchingCommitDtoAndAnotherChildCannotOpenAContentPath():Unit{
        let paths=AtomicInt64(0)
        let reader=HostDocumentPayloadCommitReader(RunId("actual-run"),OperationId("actual-parent"),OperationId("actual-child"),
            {action=>action()},{_=>let _=paths.fetchAdd(1);"/never-opened"},{=>Result<Unit>.Ok(())},reserveNativeObservationBuffer())
        try{
            let outcome=reader.runCommit({committer=>
                @Expect(committer.commit(ClaimedWindowCommitProof(OperationId("another-child"))).error().getOrThrow().code,"plugin.document_payload_scope_changed")
                committer.commit(ClaimedWindowCommitProof(OperationId("actual-child")))})
            @Expect(outcome.error().getOrThrow().code,"plugin.document_payload_proof_invalid");@Expect(paths.load(),0)
            @Expect(reader.collect(),true)
        }finally{@Expect(reader.close().isOk(),true)}
    }
    @TestCase
    func publicPayloadReferenceCannotBecomeManifestReadAuthority():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-window-artifacts"))
        try{
            let outcome=session.run({owner=>owner.readWindowManifestPages(hostWindowOwnerTestReference(),{=>Result<Unit>.Ok(())})})
            @Expect(outcome.error().getOrThrow().code,"plugin.document_query_closed")
            @Expect(session.collect(),true)
        }finally{@Expect(session.close().isOk(),true)}
    }
}
