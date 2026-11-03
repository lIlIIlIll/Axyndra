package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func explicitWorkspaceTestPlan(mode: String): AgentValue {
    objectValue([ValueField("workspace_mode", textValue(mode)),
        ValueField("workspace_root", textValue("/workspace/owned"))])
}

func explicitWorkspaceTestBinding(mode: String): AgentValue {
    let digest = modelPolicySha256Text("explicit-workspace-capabilities")
    objectValue([
        ValueField("plugin", textValue("axyndra:workspace-caps-test")),
        ValueField("package_digest", textValue("sha256:" + digest)),
        ValueField("configuration_digest", textValue(digest)),
        ValueField("instance_identity", textValue("caps-instance")),
        ValueField("endpoint_identity", textValue(digest)),
        ValueField("lease_id", textValue("caps-lease")),
        ValueField("launch_digest", textValue(digest)),
        ValueField("startup_operation_id", textValue("caps-start")),
        ValueField("target_thread_id", textValue("caps-thread")),
        ValueField("permission_domain", textValue(digest)),
        ValueField("directory_revision", integerValue(1)),
        ValueField("directory_digest", textValue(digest)),
        ValueField("implementation_version", textValue("caps-v1")),
        ValueField("implementation_fingerprint", textValue("owned-v1:" + digest)),
        ValueField("schema_digest", textValue(digest)),
        ValueField("workspace_root", textValue("/workspace/owned")),
        ValueField("workspace_mode", textValue(mode)),
        ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied)))])
}

@Test
class ExplicitWorkspaceCapabilitiesTests {
    @TestCase
    func writableLifecycleFreezesReadAndWriteWithoutInferringRead(): Unit {
        let required = hostLifecycleControlCapabilities(explicitWorkspaceTestPlan("workspace_readwrite"))
        @Expect(required.size, 3)
        @Expect(required[0].kind, CapabilityKind.ExtensionInvoke)
        @Expect(required[1].kind, CapabilityKind.WorkspaceRead)
        @Expect(required[2].kind, CapabilityKind.WorkspaceWrite)
        @Expect(required[1].resource, "/workspace/owned")
        @Expect(required[2].resource, "/workspace/owned")
        let writeOnly = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceWrite, resource: "/workspace/owned")])
        @Expect(!writeOnly.allows(CapabilityKind.WorkspaceRead, resource: "/workspace/owned"))
        @Expect(!writeOnly.allows(required[1].kind, resource: required[1].resource))
        @Expect(!CapabilitySet(values: required).allows(CapabilityKind.WorkspaceRead, resource: "/workspace/other"))
    }

    @TestCase
    func readonlyAndIsolatedLifecycleKeepTheirOriginalEffects(): Unit {
        let readonly = hostLifecycleControlCapabilities(explicitWorkspaceTestPlan("workspace_readonly"))
        @Expect(readonly.size, 2)
        @Expect(readonly[0].kind, CapabilityKind.ExtensionInvoke)
        @Expect(readonly[1].kind, CapabilityKind.WorkspaceRead)
        @Expect(!CapabilitySet(values: readonly).allows(CapabilityKind.WorkspaceWrite, resource: "/workspace/owned"))
        let isolated = hostLifecycleControlCapabilities(explicitWorkspaceTestPlan("isolated_readonly"))
        @Expect(isolated.size, 1)
        @Expect(isolated[0].kind, CapabilityKind.ExtensionInvoke)
        @Expect(!CapabilitySet(values: isolated).allows(CapabilityKind.WorkspaceRead, resource: "/workspace/owned"))
    }

    @TestCase
    func writableChannelRequiresBothEffectsAndRejectsIncompleteCeiling(): Unit {
        let result = channelServiceRequiredCapabilities(explicitWorkspaceTestBinding("workspace_readwrite"))
        @Expect(result.isOk())
        let required = result.value().getOrThrow()
        @Expect(required.size, 4)
        @Expect(required[0].kind, CapabilityKind.ProcessSpawn)
        @Expect(required[1].kind, CapabilityKind.ExtensionInvoke)
        @Expect(required[2].kind, CapabilityKind.WorkspaceRead)
        @Expect(required[3].kind, CapabilityKind.WorkspaceWrite)
        @Expect(required[2].resource, "/workspace/owned")
        @Expect(required[3].resource, "/workspace/owned")
        let writeOnly = CapabilitySet(values: [required[0], required[1], required[3]])
        @Expect(!writeOnly.allows(required[2].kind, resource: required[2].resource))
        let readOnly = channelServiceRequiredCapabilities(explicitWorkspaceTestBinding("workspace_readonly")).value().getOrThrow()
        @Expect(readOnly.size, 3)
        @Expect(readOnly[2].kind, CapabilityKind.WorkspaceRead)
        @Expect(!CapabilitySet(values: readOnly).allows(CapabilityKind.WorkspaceWrite, resource: "/workspace/owned"))
        let isolated = channelServiceRequiredCapabilities(explicitWorkspaceTestBinding("isolated_readonly")).value().getOrThrow()
        @Expect(isolated.size, 2)
    }
}
