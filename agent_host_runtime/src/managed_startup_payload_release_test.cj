package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ManagedStartupReleaseProbe {
    var releases: Int64 = 0
    func release(): Unit { releases += 1 }
}

@Test
class ManagedStartupPayloadReleaseTests {
    @TestCase
    func successfulDirectoryIsFrozenBeforeItsWireReservationIsReleased(): Unit {
        let probe = ManagedStartupReleaseProbe()
        let original = objectValue([ValueField("tools", listValue([]))])
        let response = HostJavaScriptPluginInvocationResult(original, false, releasePayload: { => probe.release() })
        let result = hostFreezeManagedProtocolStartupResponse(response, 65536)
        @Expect(result.isOk())
        @Expect(probe.releases, 1)
        original.put("mutated", boolValue(true))
        @Expect(result.value().getOrThrow().field("mutated").isNone())
        @Expect(result.value().getOrThrow().field("tools").getOrThrow().items.isEmpty())
    }

    @TestCase
    func rejectedStartupAlsoReleasesItsActualResponse(): Unit {
        let probe = ManagedStartupReleaseProbe()
        let response = HostJavaScriptPluginInvocationResult(objectValue([]), true,
            releasePayload: { => probe.release() })
        let result = hostFreezeManagedProtocolStartupResponse(response, 65536)
        @Expect(result.isError())
        @Expect(result.error().getOrThrow().code, "channel.startup_rejected")
        @Expect(probe.releases, 1)
    }

    @TestCase
    func directoryCloneFailureReleasesReservationWithoutChangingDirectoryBound(): Unit {
        let probe = ManagedStartupReleaseProbe()
        let response = HostJavaScriptPluginInvocationResult(objectValue([
            ValueField("oversized", textValue("directory clone exceeds this exact eight byte bound"))]), false,
            releasePayload: { => probe.release() })
        let result = hostFreezeManagedProtocolStartupResponse(response, 8)
        @Expect(result.isError())
        @Expect(result.error().getOrThrow().code, "plugin.lifecycle_directory_invalid")
        @Expect(probe.releases, 1)
    }
}
