package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func peerReadRequestTest111():AgentValue {
    let binding=documentTestBinding()
    binding.put("contribution",textValue("plugin.axyndra:workflow.hub"))
    objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ111)),ValueField("binding",binding),
        ValueField("projection_digest",textValue(modelPolicySha256Text("projection"))),
        ValueField("member_snapshot",objectValue([ValueField("schema",textValue("axyndra.peer-member-snapshot/v1")),
            ValueField("sender",textValue("Main")),ValueField("sender_session",binding.field("thread_id").getOrThrow()),
            ValueField("root_thread",binding.field("thread_id").getOrThrow()),ValueField("root_revision",integerValue(4)),
            ValueField("id",textValue("member")),ValueField("thread_id",textValue("child")),ValueField("run_id",textValue("old-run")),
            ValueField("status",textValue("completed")),ValueField("source_identity",textValue("plugin:old")),
            ValueField("updated_at",integerValue(1)),ValueField("execution_in_progress",boolValue(false)),
            ValueField("launch_in_progress",boolValue(false)),ValueField("finishing",boolValue(false)),
            ValueField("budget_held",boolValue(false)),ValueField("completion_done",boolValue(true))])),
        ValueField("recipient",textValue("member")),ValueField("input_payload",objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("encoding",textValue("utf8")),
            ValueField("artifact_ref",textValue("blob:sha256:"+modelPolicySha256Text("{}"))),
            ValueField("bytes",integerValue(2)),ValueField("sha256",textValue(modelPolicySha256Text("{}"))),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])),ValueField("invocation_capability",textValue("peer.message"))])
}
func peerReadPlanTest111(value:AgentValue,capabilities:Array<Capability>):NormalizedOperationPlan {
    NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,value,capabilities,OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,"peer-read-test",toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,
        implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
}

@Test
class PluginPeerRead111Tests {
    @TestCase
    func peerCapabilityCannotFallThroughToFilesystemReadOrDelegation():Unit {
        let value=peerReadRequestTest111()
        @Expect(pluginPeerReadRequestValid111(value))
        @Expect(isContextReadPlan(peerReadPlanTest111(value,[Capability(CapabilityKind.PeerMessage)])))
        for(kind in [CapabilityKind.WorkspaceRead,CapabilityKind.Delegate,CapabilityKind.ExtensionInvoke]) {
            @Expect(!isContextReadPlan(peerReadPlanTest111(value,[Capability(kind)]))) }
        for(field in ["namespace","generation","configuration_digest","thread_id","parent_call_id"]) {
            let invalid=peerReadRequestTest111()
            invalid.field("binding").getOrThrow().put(field,textValue(""))
            @Expect(!isContextReadPlan(peerReadPlanTest111(invalid,[Capability(CapabilityKind.WorkspaceRead)]))) }
        value.put("requires_approval",boolValue(false))
        @Expect(!pluginPeerReadRequestValid111(value))
        @Expect(!isContextReadPlan(peerReadPlanTest111(value,[Capability(CapabilityKind.WorkspaceRead)])))
    }
    @TestCase
    func completeInvocationSelectionAndEveryFrozenInputRemainInPlanDigest():Unit {
        let plain=peerReadRequestTest111()
        let expected=contextReadPlanDigest(peerReadPlanTest111(plain,[Capability(CapabilityKind.PeerMessage)]))
        for(field in ["recipient","input_payload"]) {
            let changed=peerReadRequestTest111()
            if(field=="recipient"){
                changed.put(field,textValue("changed"))
                changed.field("member_snapshot").getOrThrow().put("id",textValue("changed"))
            }else{
                let payload=changed.field(field).getOrThrow();let digest=modelPolicySha256Text("[]")
                payload.put("sha256",textValue(digest));payload.put("artifact_ref",textValue("blob:sha256:"+digest))}
            @Expect(pluginPeerReadRequestValid111(changed))
            @Expect(isContextReadPlan(peerReadPlanTest111(changed,[Capability(CapabilityKind.PeerMessage)])))
            @Expect(expected!=contextReadPlanDigest(peerReadPlanTest111(changed,[Capability(CapabilityKind.PeerMessage)]))) }
        let mismatched=peerReadRequestTest111()
        mismatched.put("recipient",textValue("changed"))
        @Expect(!pluginPeerReadRequestValid111(mismatched))
        @Expect(!isContextReadPlan(peerReadPlanTest111(mismatched,[Capability(CapabilityKind.PeerMessage)])))
        let extension=peerReadRequestTest111();extension.put("invocation_capability",textValue("extension.invoke"))
        let caps=[Capability(CapabilityKind.PeerMessage),Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")]
        @Expect(isContextReadPlan(peerReadPlanTest111(extension,caps)))
        @Expect(expected!=contextReadPlanDigest(peerReadPlanTest111(extension,caps)))
        @Expect(!isContextReadPlan(peerReadPlanTest111(extension,[Capability(CapabilityKind.PeerMessage)])))
        @Expect(!isContextReadPlan(peerReadPlanTest111(extension,[Capability(CapabilityKind.PeerMessage),
            Capability(CapabilityKind.ExtensionInvoke,resource:"another:package")])))
    }
}
