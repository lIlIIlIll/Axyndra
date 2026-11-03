package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerResumeStoreRequire111<T>(value:Result<T>):T {
    match(value){case Result.Ok(found)=>found;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
private class PeerResumeStoreEstimator111 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
// Actual canonical Direct/read/Derived owners and SQLite, not a fabricated
// ContextRead origin. Task launch remains the separate installed Product test.
private class PeerResumeStoreFixture111 {
    let root:String
    let database:SqliteDatabase
    let runtime:AgentThreadRuntime
    let store:DurableOperationStore
    let thread=ThreadId("resume-thread")
    let run=RunId("resume-run")
    let parent=OperationId("resume-parent")
    let child=OperationId("resume-child")
    let readId=OperationId("resume-read")
    let active:ActiveRunSnapshot
    let source:DirectToolCallRef
    let parentPlan:NormalizedOperationPlan
    let childPlan:NormalizedOperationPlan
    init(){
        root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();database=SqliteDatabase(root+"/resume.sqlite")
        let sink=SqliteThreadCommitSink(database);let turn=SemanticTurnId("resume-turn")
        runtime=AgentThreadRuntime(ThreadCoordinator(sink.createThread(thread,"workspace"),sink),
            ContextProjector("resume",PeerResumeStoreEstimator111()),{=>10})
        let lane=ModelLane(ModelLaneRole.Main,"provider","model","responses",ModelLaneCapabilitiesSnapshot(),100,10,5,
            "estimator","retry","cache",ToolSetSnapshot("tools",[]),"system")
        active=peerResumeStoreRequire111(runtime.startTurn(turn,run,ItemId("resume-user"),
            ThreadItemContent.UserMessage(textMessageParts("send to the settled member")),lane,InvocationContextProjection()))
        let original=objectValue([ValueField("op",textValue("send")),ValueField("to",textValue("member")),ValueField("message",textValue("actual message"))])
        let call=ToolCall("resume-call","plugin.axyndra:workflow.hub",original)
        @Expect(match(runtime.commitResult(ResultEnvelope(thread,turn,run,active.epoch,1,
            ThreadItemDraft(ItemId("resume-parent-item"),ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId),call.name,original),
                ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parent)))))){
            case SemanticCommitDecision.Committed(_,_)=>true;case _=>false})
        source=peerResumeStoreRequire111(runtime.attestDirectToolCall(ItemId("resume-parent-item"),parent,run,active.epoch))
        store=DurableOperationStore(database)
        let digest=modelPolicySha256Text("actual resume store fixture");let packageDigest="sha256:"+digest
        let binding=objectValue([ValueField("namespace",textValue("axyndra:workflow")),ValueField("package_digest",textValue(packageDigest)),
            ValueField("generation",textValue("1")),ValueField("configuration_digest",textValue(digest)),ValueField("thread_id",textValue(thread.value)),
            ValueField("lane_id",textValue(peerResumeStoreRequire111(store.pluginDocumentLane(thread,run,active.epoch)).value)),
            ValueField("run_id",textValue(run.value)),ValueField("epoch",integerValue(active.epoch)),ValueField("parent_call_id",textValue(call.callId)),
            ValueField("contribution",textValue(call.name)),ValueField("implementation_fingerprint",textValue("resume-fixture")),ValueField("schema_digest",textValue(digest))])
        let raw=encodeAgentValue(original);let inputDigest=modelPolicySha256Text(raw)
        let payload=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("encoding",textValue("utf8")),
            ValueField("artifact_ref",textValue("blob:sha256:"+inputDigest)),ValueField("bytes",integerValue(raw.size)),
            ValueField("sha256",textValue(inputDigest)),ValueField("content_type",textValue("text/plain; charset=utf-8"))])
        let snapshot=objectValue([ValueField("schema",textValue("axyndra.peer-member-snapshot/v1")),ValueField("sender",textValue("Main")),
            ValueField("sender_session",textValue(thread.value)),ValueField("root_thread",textValue(thread.value)),ValueField("root_revision",integerValue(1)),
            ValueField("id",textValue("member")),ValueField("thread_id",textValue("member-thread")),ValueField("run_id",textValue("prior-run")),
            ValueField("status",textValue("completed")),ValueField("source_identity",textValue("plugin:prior")),ValueField("updated_at",integerValue(1)),
            ValueField("execution_in_progress",boolValue(false)),ValueField("launch_in_progress",boolValue(false)),ValueField("finishing",boolValue(false)),
            ValueField("budget_held",boolValue(false)),ValueField("completion_done",boolValue(true))])
        let projection=contextReadProjectionDigest(active.contextSnapshot)
        let request=objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ111)),ValueField("binding",binding),ValueField("projection_digest",textValue(projection)),
            ValueField("recipient",textValue("member")),ValueField("input_payload",payload),ValueField("invocation_capability",textValue("peer.message")),
            ValueField("member_snapshot",snapshot)])
        let readCall=ToolCall("read-call",HOST_CONTEXT_READ_TOOL,request)
        let caps=[Capability(CapabilityKind.PeerMessage)]
        let readPlan=NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,request,caps,OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,
            modelPolicySha256Text(canonicalAgentValue(request)),toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
        let readAdmission=peerResumeStoreRequire111(runtime.beginContextRead(readCall,"axyndra:workflow",packageDigest,digest,"read-request",run,active.epoch,
            projection,parent:Some(OperationRootSource.Direct(source))))
        let readSource=peerResumeStoreRequire111(runtime.commitContextReadToolCall(readAdmission,ItemId("resume-read-item"),readId,readCall,readPlan))
        peerResumeStoreRequire111(store.prepareDirectOperation(readSource,readPlan))
        peerResumeStoreRequire111(store.markExecutingWithSource(Some(OperationRootSource.Direct(readSource)),readId,run,readPlan,11,false))
        peerResumeStoreRequire111(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(readSource)),readId,run,thread,12))
        let completion=objectValue([ValueField("provider",textValue("prepare_child")),ValueField("input",objectValue([])),
            ValueField("input_sha256",textValue(modelPolicySha256Text("{}")))])
        let target=objectValue([ValueField("id",textValue("member")),ValueField("thread_id",textValue("member-thread")),ValueField("run_id",textValue("prior-run")),
            ValueField("status",textValue("completed")),ValueField("source_identity",textValue("plugin:prior")),ValueField("capability_ceiling",listValue([])),
            ValueField("definition",objectValue([ValueField("request",objectValue([])),ValueField("completion",completion)]))])
        let output=objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ_RESULT111)),ValueField("binding",binding),ValueField("projection_digest",textValue(projection)),
            ValueField("request_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),ValueField("observation",objectValue([
                ValueField("sender",textValue("Main")),ValueField("sender_session",textValue(thread.value)),ValueField("root_thread",textValue(thread.value)),
                ValueField("counter",integerValue(0)),ValueField("message",objectValue([ValueField("id",textValue("message-1")),ValueField("input_payload",payload),
                    ValueField("created_at",integerValue(13))])),ValueField("target",target)]))])
        @Expect(pluginPeerReadResultValid111(output,request))
        let resolution=peerResumeStoreRequire111(runtime.resolveOperation(ItemId("result-"+readId.value),readId,CanonicalToolCallId(readCall.callId),readPlan,
            OperationAttemptStage.Executing,Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(readCall.callId,output))),
            "receipt-"+readId.value,14,expectedRunId:Some(run),expectedEpoch:Some(active.epoch)))
        @Expect(match(resolution.semanticCommit.getOrThrow()){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false})
        let fact=peerResumeStoreRequire111(store.loadContextReadFact(readId,run));let link=fact.link()
        let proposal=objectValue([ValueField("schema",textValue("axyndra.peer-resume-proposal/v1")),ValueField("fact_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(output)))),
            ValueField("target",target),ValueField("message",objectValue([ValueField("id",textValue("message-1")),ValueField("body",textValue("actual message")),
                ValueField("reply_to",textValue("")),ValueField("created_at",integerValue(13))])),ValueField("request",objectValue([
                    ValueField("prompt",textValue("frozen request")),ValueField("system_prompt",textValue("role")),ValueField("cache_key",textValue("cache")),
                    ValueField("capability_ceiling",listValue([])),ValueField("requested_limits",objectValue([]))])),ValueField("completion",completion)])
        let intent=objectValue([ValueField("id",textValue("send-0")),ValueField("service",textValue("peer.send")),ValueField("input",objectValue([
            ValueField("recipient",objectValue([ValueField("kind",textValue("member")),ValueField("id",textValue("member"))])),
            ValueField("body",textValue("actual message")),ValueField("reply_to",textValue("")),ValueField("format",completion),
            ValueField("resume",objectValue([ValueField("read_request",request),ValueField("read_fact",output),ValueField("proposal",proposal)]))]))])
        let enriched=parseUnifiedJson(raw)
        enriched.put(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",output),
            ValueField("facts",contextReadFactLinksValue([link]))]))
        let arguments=objectValue([ValueField("input",enriched),ValueField("configuration",objectValue([])),ValueField("host_plan",objectValue([
            ValueField("version",textValue(PLUGIN_PRIMITIVE_PARENT111)),ValueField("binding",binding),ValueField("intents",listValue([intent])),
            ValueField("invocation_capability",textValue("peer.message"))]))])
        parentPlan=NormalizedOperationPlan(call.name,arguments,caps,OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,
            modelPolicySha256Text(canonicalAgentValue(arguments)),networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),
            replayDisposition:Some(ReplayDisposition.NeverReplay),toolVersion:"fixture",implementationFingerprint:"resume-fixture",schemaDigest:digest,contextReadFacts:[link])
        let childArguments=peerResumeStoreRequire111(pluginChildStartArguments111(arguments,"send-0"))
        childPlan=NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111,childArguments,caps,OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,
            modelPolicySha256Text(canonicalAgentValue(childArguments)),networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),
            replayDisposition:Some(ReplayDisposition.NeverReplay),toolVersion:HOST_PLUGIN_CHILD_FINGERPRINT111,implementationFingerprint:HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func handoff():Unit {
        peerResumeStoreRequire111(store.prepareDirectOperation(source,parentPlan))
        peerResumeStoreRequire111(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),parent,run,parentPlan,15,false))
        peerResumeStoreRequire111(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),parent,run,thread,16))
        peerResumeStoreRequire111(store.prepareDerivedOperation(child,parent,run,OperationRootSource.Direct(source),exactServiceRequestKey(source.call.callId,childPlan),childPlan))
        peerResumeStoreRequire111(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),child,run,childPlan,17,false))
        peerResumeStoreRequire111(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),child,run,thread,18))
    }
    func verify():Result<Unit>{store.verifyPluginChildExecution111(OperationRootSource.Direct(source),parent,child,run,thread,active.epoch,childPlan)}
    func close():Unit{database.close();remove(root,recursive:true)}
}

@Test
class PluginPeerResumeScopeTests111 {
    @TestCase
    func exactCompletedReadEnablesOneSameRunDerivedProofAndReceiptClosesIt():Unit {
        let f=PeerResumeStoreFixture111()
        try {
            @Expect(f.verify().isError());f.handoff();@Expect(f.verify().isOk())
            let duplicate=peerResumeStoreRequire111(f.store.prepareDerivedOperation(OperationId("replayed-resume"),f.parent,f.run,
                OperationRootSource.Direct(f.source),exactServiceRequestKey(f.source.call.callId,f.childPlan),f.childPlan))
            @Expect(duplicate.value,f.child.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            peerResumeStoreRequire111(f.store.settleDerivedOperation(f.run,f.parent,VNextOperationReceipt("receipt-"+f.child.value,f.child,
                OperationOutcome.Completed,objectValue([]),objectValue([]),19)))
            @Expect(f.verify().isError());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),2)
        }finally{f.close()}
    }
    @TestCase
    func deletedReadProofChangedStoredResultOrStaleEpochCannotRetainAnExecutingResume():Unit {
        for(mode in ["admission","result","epoch"]){let f=PeerResumeStoreFixture111()
            try {
                f.handoff();@Expect(f.verify().isOk())
                if(mode=="admission"){f.database.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'")}
                else if(mode=="result"){f.database.execute("UPDATE items SET payload='invalid' WHERE id='result-resume-read'")}
                else{f.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='resume-run'")}
                @Expect(f.verify().isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),3)
            }finally{f.close()}
        }
    }
}
