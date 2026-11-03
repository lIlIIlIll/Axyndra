package agent_extension_runtime

import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CommandControlManifestTests {
    @TestCase
    func explicitCommandControlIsDataAndLeavesCapabilitiesEmpty(): Unit {
        for (suffix in ["", ",\"allowed_user_controls\":[\"continuation\"]"]) {
            let result = parsePluginPackageManifest(PluginManifestFamily.Axyndra,
                nativeCommandManifest().replace("\"name\":\"hello\"", "\"name\":\"hello\"" + suffix))
            @Expect(match (result) { case PluginPackageResult.Ok(value) =>
                value.requestedCapabilities.isEmpty() && value.contributions.size == 1 &&
                value.contributions[0].allowedUserControls().size == (if (suffix == "") { 0 } else { 1 })
                case _ => false })
        }
    }

    @TestCase
    func rejectsWrongKindTypeUnknownAndRepeatedControl(): Unit {
        for (value in ["null", "true", "\"continuation\"", "[]", "[\"unknown\"]", "[\"continuation\",\"continuation\"]"]) {
            @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"name\":\"hello\"",
                "\"name\":\"hello\",\"allowed_user_controls\":" + value), "plugin.contribution_invalid", "contributions"))
        }
        for (kind in ["tool", "provider", "service", "context_provider", "model_provider"]) {
            let manifest = nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"" + kind + "\"")
                .replace("\"name\":\"hello\"", "\"name\":\"hello\",\"allowed_user_controls\":[\"continuation\"]")
            @Expect(nativeManifestHasError(manifest, "plugin.contribution_invalid", "contributions"))
        }
    }
}
