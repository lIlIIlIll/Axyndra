package agent_extension_runtime

import agent_domain.{ServiceProtocolLimits, parseServiceProtocolLimits}
import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func longServiceProfile(): ServiceProtocolLimits {
    parseServiceProtocolLimits(parseUnifiedJson("{\"max_frame_bytes\":524288,\"max_input_bytes\":16384,\"max_prepare_bytes\":131072,\"max_result_bytes\":262144,\"max_directory_bytes\":65536,\"max_tools\":64,\"call_timeout_ms\":1800000}")).value().getOrThrow()
}

@Test
class NativeServiceDeadlineTests {
    @TestCase
    func longTimeoutRequiresExactExplicitNativeServiceProfile(): Unit {
        let profile = longServiceProfile()
        let configured = JavaScriptHostLaunchRequest("/tmp", "worker", extensionId: "long-service", extensionVersion: "1.0.0",
            profile: JavaScriptHostLaunchProfile.NativeExecutable, maxFrameBytes: profile.maxFrameBytes,
            defaultTimeoutMillis: 1800000, serviceLimits: Some(profile),
            contributions: [PluginContributionDefinition("session", PluginContributionKind.Service)])
        @Expect(configured.defaultTimeoutMillis, 1800000)
        for (mode in ["ordinary", "native-unconfigured", "above-profile"]) {
            var rejected = false
            try {
                let _ = JavaScriptHostLaunchRequest("/tmp", "worker", extensionId: "invalid-long", extensionVersion: "1.0.0",
                    profile: if (mode == "ordinary") { JavaScriptHostLaunchProfile.ProtocolWorker } else { JavaScriptHostLaunchProfile.NativeExecutable },
                    maxFrameBytes: profile.maxFrameBytes, defaultTimeoutMillis: if (mode == "above-profile") { 1800001 } else { 1800000 },
                    serviceLimits: if (mode == "native-unconfigured") { None } else { Some(profile) },
                    contributions: [PluginContributionDefinition("session", PluginContributionKind.Service)])
            } catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected)
        }
    }
}
