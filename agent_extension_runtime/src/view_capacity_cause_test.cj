package agent_extension_runtime

import agent_sdk.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ViewHandshakeCapacityCauseTests {
    @TestCase
    func sharedCapacityRefusalIsNotReportedAsAnOversizedReadyFrame(): Unit {
        let root = policyProviderFixture("echo")
        let worker = String.fromUtf8(File.readFrom(root + "/worker"))
            .replace("tools=[]", "tools=[],views=[dict(name='plan_review',description='Pure declarative view')]")
            .replace("  emit(r);continue\n", "  (root/'ready-wire-bytes').write_text(str(len(json.dumps(r,separators=(',',':')).encode())+1))\n  emit(r);continue\n")
        File.writeTo(root + "/worker", worker.toArray())
        let request = JavaScriptHostLaunchRequest(root, "worker", extensionId: "content-payload",
            extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
            contentPayload: true, contributions: [PluginContributionDefinition("context", PluginContributionKind.Provider),
                PluginContributionDefinition("plan_review", PluginContributionKind.View)])
        try {
            match (startJavaScriptExtensionHostWithLauncher(request, ServiceQuotaFixtureLauncher())) {
                case JavaScriptHostResult.Ok(host) =>
                    @Expect(host.views.size, 1)
                    @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let readyBytes = Int64.parse(String.fromUtf8(File.readFrom(root + "/ready-wire-bytes")))
            @Expect(readyBytes < request.maxFrameBytes)
            let baseline = nativeControlMetadataUsage113()
            let pressure = reserveNativeControlMetadata(4096)
            try {
                let before = nativeControlMetadataUsage113()
                pressure.ensureRetainedPeak(16777216 + nativeControlMetadataCapacity113() - before[1] - 1048576)
                let saturated = nativeControlMetadataUsage113()
                @Expect(saturated[1], nativeControlMetadataCapacity113() - 1048576)
                match (startJavaScriptExtensionHostWithLauncher(request, ServiceQuotaFixtureLauncher())) {
                    case JavaScriptHostResult.Ok(host) =>
                        let _ = host.awaitCleanup(timeoutMillis: 2000)
                        @Fail("saturated shared bank must refuse the actual handshake reservation")
                    case JavaScriptHostResult.Err(error) =>
                        @Expect(error.code, "extension.payload_capacity")
                        match (error.cleanupHost) {
                            case Some(host) => @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
                            case None => ()
                        }
                }
                @Expect(nativeControlMetadataUsage113()[1], saturated[1])
            } finally { pressure.close() }
            @Expect(nativePayloadUsageEqual(nativeControlMetadataUsage113(), baseline))
            match (startJavaScriptExtensionHostWithLauncher(request, ServiceQuotaFixtureLauncher())) {
                case JavaScriptHostResult.Ok(host) =>
                    @Expect(host.views[0].name, "plan_review")
                    @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk())
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(nativePayloadUsageEqual(nativeControlMetadataUsage113(), baseline))
        } finally { remove(root, recursive: true) }
    }
}
