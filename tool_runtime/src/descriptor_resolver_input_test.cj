package tool_runtime

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func resolverInputExpired(input: ToolResolverInput): Bool {
    try { let _ = input.kind([]); false } catch (_: IllegalStateException) { true }
}

@Test
class DescriptorResolverInputTests {
    @TestCase
    func allFiveCallbacksReceiveLiveDataAndCannotKeepTheArgumentGraph(): Unit {
        let stored = ArrayList<ToolResolverInput>()
        let bytes = Array<Byte>(2, repeat: 0)
        let descriptor = ToolDescriptor(ModelToolDefinition("probe", "read policy", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            capabilityResolver: Some({ input =>
                stored.add(input)
                let path = [ToolResolverStep.Field("limits"), ToolResolverStep.Index(0)]
                if (input.textEquals(ToolResolverText.Scalar(path), "1.50")) { Capability(CapabilityKind.ProcessSpawn) }
                else { Capability(CapabilityKind.WorkspaceRead) }
            }),
            additionalCapabilityResolver: Some({ input =>
                stored.add(input)
                if (input.boolean([ToolResolverStep.MemberAt(1)])) { [Capability(CapabilityKind.WorkspaceWrite)] }
                else { [] }
            }),
            networkPolicyResolver: Some({ input =>
                stored.add(input)
                if (!input.textEquals(ToolResolverText.Name, "probe")) { throw IllegalArgumentException("wrong name") }
                Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
            }),
            sideEffectResolver: Some({ input =>
                stored.add(input)
                input.count([ToolResolverStep.Field("limits")]) == 1 && input.kind([ToolResolverStep.Index(0)]).isNone()
            }),
            approvalMetadataResolver: Some({ input =>
                stored.add(input)
                let key = ToolResolverText.Key([], 0)
                if (input.byteCount(key) != 6 || input.readBytes(key, 1, bytes) != 2) { throw IllegalStateException("wrong key") }
                defaultToolApprovalMetadata(Capability(CapabilityKind.WorkspaceRead))
            }))
        let result = descriptor.resolved(ToolCall("id", "probe", objectValue([
            ValueField("limits", listValue([JsonNode.number("1.50")])), ValueField("enabled", boolValue(true))
        ])))
        @Expect(result.capability.kind == CapabilityKind.ProcessSpawn)
        @Expect(result.additionalCapabilities.size, 1)
        @Expect(result.additionalCapabilities[0].kind == CapabilityKind.WorkspaceWrite)
        @Expect(result.sideEffecting)
        @Expect(String.fromUtf8(bytes), "im")
        @Expect(stored.size, 5)
        for (input in stored) { @Expect(resolverInputExpired(input)) }
    }

    @TestCase
    func aThrowingResolverCannotRetainItsInputAfterUnwind(): Unit {
        let stored = ArrayList<ToolResolverInput>()
        let desc = ToolDescriptor(ModelToolDefinition("failing", "", objectValue([])), Capability(CapabilityKind.WorkspaceRead),
            networkPolicyResolver: Some({ input =>
                stored.add(input)
                if (input.textEquals(ToolResolverText.CallId, "failed")) { throw IllegalArgumentException("declined") }
                Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
            }))
        var declined = false
        try { let _ = desc.networkPolicy(ToolCall("failed", "failing", nullValue())) }
        catch (error: IllegalArgumentException) { declined = error.message == "declined" }
        @Expect(declined)
        @Expect(resolverInputExpired(stored[0]))
    }
}
