package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func managedPlanTestBinding(active!:Bool=false,lease!:String="adapter-lease"):AgentValue{
    let digest=String.fromUtf8(Array<Byte>(64,repeat:b'a'))
    let value=objectValue([ValueField("plugin",textValue("axyndra:dap")),ValueField("package_digest",textValue("sha256:"+digest)),
        ValueField("configuration_digest",textValue(digest)),ValueField("instance_identity",textValue("instance-1")),
        ValueField("endpoint_identity",textValue(digest)),ValueField("directory_revision",numberValue("1")),
        ValueField("directory_digest",textValue(digest)),ValueField("implementation_version",textValue("1")),
        ValueField("implementation_fingerprint",textValue("owned-v1:"+digest)),ValueField("schema_digest",textValue(digest)),
        ValueField("target_thread_id",textValue("thread-1")),ValueField("permission_domain",textValue(digest)),
        ValueField("workspace_root",textValue("/workspace")),ValueField("workspace_mode",textValue("workspace_readonly")),
        ValueField("network",networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
        ValueField("launch_digest",textValue(digest)),ValueField("lane_id",textValue("main")),ValueField("run_id",textValue("run-1")),
        ValueField("epoch",numberValue("1")),ValueField("resource_state",textValue(if(active){"active"}else{"planned"})),
        ValueField("lifecycle_policy",processShutdownPolicyValue(3000))])
    if(active){value.put("lease_id",textValue(lease));value.put("startup_operation_id",textValue("spawn-"+lease))}
    value
}
func managedPlanTestParent(binding:AgentValue):NormalizedOperationPlan{
    let digest=httpIntentText(binding,"schema_digest")
    NormalizedOperationPlan("plugin.axyndra:dap.service.session.stackTrace",
        objectValue([ValueField("input",objectValue([])),ValueField("configuration",objectValue([])),
            ValueField("host_plan",objectValue([ValueField("version",textValue(HOST_MANAGED_CHANNEL_OWNED_VERSION)),ValueField("binding",binding)]))]),
        managedChannelRuntimeRequiredCapabilities(binding).value().getOrThrow(),OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,digest,
        networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
        toolVersion:"1",implementationFingerprint:httpIntentText(binding,"implementation_fingerprint"),schemaDigest:digest)
}
func managedPlanTestWrite(binding:AgentValue,sequence!:String="1",bytes!:String="6100e99baa"):NormalizedOperationPlan{
    let digest=httpIntentText(binding,"schema_digest")
    NormalizedOperationPlan(HOST_MANAGED_CHANNEL_WRITE_TOOL,
        objectValue([ValueField("binding",binding),ValueField("sequence",numberValue(sequence)),
            ValueField("request_key",textValue("managed-channel:parent-call:"+sequence)),
            ValueField("operation",objectValue([ValueField("kind",textValue("write")),ValueField("lease_id",binding.field("lease_id").getOrThrow()),
                ValueField("id",textValue("request-1")),ValueField("bytes_hex",textValue(bytes))]))]),
        managedChannelRuntimeRequiredCapabilities(binding).value().getOrThrow(),OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,digest,
        networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
        implementationFingerprint:HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT,schemaDigest:digest)
}

@Test
class ManagedChannelRuntimePlanTests{
    @TestCase
    func shutdownPolicyPreservesFullInt64AndCannotWidenTheFrozenCeiling():Unit{
        for(grace in [0,3000,Int64.Max]){
            @Expect(processShutdownPolicyGrace(processShutdownPolicyValue(grace)).value().getOrThrow(),grace)}
        for(encoded in ["-1","1.0","1e0","9223372036854775808"]){
            let policy=objectValue([ValueField("schema",textValue("axyndra.process-shutdown/v1")),ValueField("grace_ms",numberValue(encoded))])
            @Expect(processShutdownPolicyGrace(policy).isError(),true)}
        let binding=managedPlanTestBinding(active:true)
        let operation=objectValue([ValueField("kind",textValue("close")),ValueField("lease_id",binding.field("lease_id").getOrThrow()),
            ValueField("grace_ms",numberValue("3000"))])
        let child=objectValue([ValueField("binding",binding),ValueField("sequence",numberValue("1")),
            ValueField("request_key",textValue("managed-channel:parent-call:1")),ValueField("operation",operation)])
        @Expect(managedChannelRuntimeChildValueValid(child),true)
        operation.put("grace_ms",numberValue("3001"))
        @Expect(managedChannelRuntimeChildValueValid(child),false)
        operation.put("grace_ms",numberValue("0"))
        @Expect(managedChannelRuntimeChildValueValid(child),true)
        let parent=managedPlanTestParent(managedPlanTestBinding())
        @Expect(processShutdownPlanGrace(parent).isError(),true)
        @Expect(processShutdownPlanGrace(managedPlanTestWrite(binding)).isError(),true)
        binding.put("lifecycle_policy",processShutdownPolicyValue(3001))
        @Expect(managedChannelOwnedChildAllowed(parent,managedPlanTestWrite(binding)),false)
    }
    @TestCase
    func plannedStartupCannotInventACompletedLeaseOrReadonlyGrant():Unit{
        let planned=managedPlanTestBinding()
        @Expect(validateManagedChannelRuntimeBinding(planned).isError(),false)
        @Expect(planned.field("lease_id").isNone(),true)
        @Expect(isManagedChannelOwnedParentPlan(managedPlanTestParent(planned)),true)
        planned.put("lease_id",textValue("invented"))
        @Expect(validateManagedChannelRuntimeBinding(planned).isError(),true)
        let readonly=managedPlanTestBinding()
        let parent=managedPlanTestParent(readonly)
        readonly.put("read_only_tool",textValue("stackTrace"))
        @Expect(validateManagedChannelRuntimeBinding(readonly).isError(),true)
        @Expect(isManagedChannelOwnedParentPlan(parent),false)
    }
    @TestCase
    func auxiliaryResourceNeedsItsOwnFullPlanAndNeverEntersOldExactIntentAuthority():Unit{
        let parent=managedPlanTestParent(managedPlanTestBinding(active:true))
        let auxiliary=managedPlanTestWrite(managedPlanTestBinding(active:true,lease:"auxiliary-lease"))
        @Expect(isManagedChannelOwnedChildPlan(auxiliary),true)
        @Expect(managedChannelOwnedChildAllowed(parent,auxiliary),true)
        @Expect(isExactServiceChildPlan(auxiliary),false)
        @Expect(exactServiceChildAllowed(parent,auxiliary),false)
        @Expect(managedChannelOwnedRequestKey("parent-call",auxiliary),"managed-channel:parent-call:1")
        @Expect(auxiliary.requiredCapabilities[0].kind,CapabilityKind.ProcessSpawn)
        @Expect(auxiliary.requiredCapabilities[0].resource,"")
        @Expect(auxiliary.requiredCapabilities[1].kind,CapabilityKind.ExtensionInvoke)
        @Expect(auxiliary.requiredCapabilities[2].kind,CapabilityKind.WorkspaceRead)
    }
    @TestCase
    func changedConfigurationMalformedBytesAndNoncanonicalOrdinalLoseThePrecisePlan():Unit{
        let parent=managedPlanTestParent(managedPlanTestBinding())
        let other=managedPlanTestBinding(active:true)
        other.put("configuration_digest",textValue(String.fromUtf8(Array<Byte>(64,repeat:b'b'))))
        @Expect(managedChannelOwnedChildAllowed(parent,managedPlanTestWrite(other)),false)
        for(bytes in ["","a","AA","0g"]){@Expect(isManagedChannelOwnedChildPlan(managedPlanTestWrite(managedPlanTestBinding(active:true),bytes:bytes)),false)}
        for(sequence in ["0","-1","1.0","1e0"]){@Expect(isManagedChannelOwnedChildPlan(managedPlanTestWrite(managedPlanTestBinding(active:true),sequence:sequence)),false)}
    }
}
