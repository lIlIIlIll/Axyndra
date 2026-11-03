package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func managedConfiguredControlValue():AgentValue{
    let binding=managedPlanTestBinding()
    objectValue([ValueField("binding",binding),ValueField("sequence",integerValue(1)),
        ValueField("request_key",textValue("managed-channel:parent-call:1")),
        ValueField("operation",objectValue([ValueField("kind",textValue("spawn")),ValueField("role",textValue("adapter")),
            ValueField("configured_process",textValue("secondary")),ValueField("executable",textValue("/usr/bin/python3")),
            ValueField("args",listValue([textValue("-u")])),ValueField("cwd",textValue("/workspace")),
            ValueField("environment",objectValue([])),ValueField("workspace_mode",binding.field("workspace_mode").getOrThrow()),
            ValueField("network",binding.field("network").getOrThrow())]))])
}
@Test
class ManagedConfiguredProcessPlanTests{
    @TestCase
    func selectedIdentityStaysInsideCompleteOrdinarySpawnPlanAndParentBinding():Unit{
        let value=managedConfiguredControlValue();@Expect(managedChannelRuntimeChildValueValid(value),true)
        let binding=value.field("binding").getOrThrow();let digest=httpIntentText(binding,"schema_digest")
        let child=NormalizedOperationPlan(HOST_MANAGED_CHANNEL_SPAWN_TOOL,value,
            managedChannelRuntimeRequiredCapabilities(binding).value().getOrThrow(),OperationEffectClass.ExternalMutation,
            OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(value)),
            networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
            implementationFingerprint:HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT,schemaDigest:digest)
        @Expect(isManagedChannelOwnedChildPlan(child),true)
        @Expect(managedChannelOwnedChildAllowed(managedPlanTestParent(managedPlanTestBinding()),child),true)
        @Expect(isExactServiceChildPlan(child),false)
        @Expect(managedChannelOwnedRequestKey("parent-call",child),"managed-channel:parent-call:1")
    }
    @TestCase
    func callerIdentityCannotWidenAuxiliaryOrAlterNetworkScope():Unit{
        for(mode in ["auxiliary","empty","number","network"]){
            let value=managedConfiguredControlValue();let operation=value.field("operation").getOrThrow()
            if(mode=="auxiliary"){operation.put("role",textValue("auxiliary"))}
            else if(mode=="empty"){operation.put("configured_process",textValue(""))}
            else if(mode=="number"){operation.put("configured_process",integerValue(1))}
            else{operation.put("network",networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.HostNetwork)))}
            @Expect(managedChannelRuntimeChildValueValid(value),false)
        }
    }
}
