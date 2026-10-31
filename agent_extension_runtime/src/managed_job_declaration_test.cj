package agent_extension_runtime

import agent_sdk.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ManagedJobDeclarationTests {
    @TestCase
    func referenceSupportDefaultsOffAndIsExplicitServiceOnlyMetadata(): Unit {
        @Expect(!PluginContributionDefinition("legacy", PluginContributionKind.Service).supportsPreparationReference)
        @Expect(PluginContributionDefinition("modern", PluginContributionKind.Service,
            supportsPreparationReference: true).supportsPreparationReference)
        for (kind in [PluginContributionKind.Tool, PluginContributionKind.Command, PluginContributionKind.ModelProvider,
            PluginContributionKind.ContextProvider, PluginContributionKind.ResourceProvider]) {
            @Expect(try { PluginContributionDefinition("unsupported", kind, supportsPreparationReference: true); false }
                catch (_: Exception) { true })
        }
        let service = nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"service\"")
        for ((suffix, expected) in [("", false), (",\"supports_preparation_reference\":false", false),
            (",\"supports_preparation_reference\":true", true)]) {
            let manifest = service.replace("\"name\":\"hello\"", "\"name\":\"hello\"" + suffix)
            @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, manifest)) {
                case PluginPackageResult.Ok(value) => value.contributions[0].supportsPreparationReference == expected &&
                    value.requestedCapabilities.isEmpty()
                case _ => false })
        }
        for (flag in ["null", "1", "\"true\""]) {
            @Expect(nativeManifestHasError(service.replace("\"name\":\"hello\"",
                "\"name\":\"hello\",\"supports_preparation_reference\":" + flag), "plugin.contribution_invalid", "contributions"))
        }
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"name\":\"hello\"",
            "\"name\":\"hello\",\"supports_preparation_reference\":true"), "plugin.contribution_invalid", "contributions"))
    }

    @TestCase
    func readyDeclarationRejectsWrongTypeAndMatchesTheManifestExactly(): Unit {
        for ((suffix, expected) in [("", false), (",\"supports_preparation_reference\":false", false),
            (",\"supports_preparation_reference\":true", true)]) {
            let frame = parseUnifiedJson("{\"services\":[{\"name\":\"session\",\"description\":\"bounded\"" + suffix + "}]}")
            @Expect(match (parsePluginServices(frame)) { case JavaScriptHostResult.Ok(values) =>
                values.size == 1 && values[0].supportsPreparationReference == expected
                case _ => false })
        }
        for (suffix in [",\"supports_preparation_reference\":null", ",\"supports_preparation_reference\":1",
            ",\"supports_preparation_reference\":\"true\"", ",\"extra\":true",
            ",\"supports_preparation_reference\":true,\"extra\":false"]) {
            @Expect(match (parsePluginServices(parseUnifiedJson("{\"services\":[{\"name\":\"session\",\"description\":\"\"" + suffix + "}]}"))) {
                case JavaScriptHostResult.Err(error) => error.code == "extension.service_invalid"
                case _ => false })
        }
        for (declared in [false, true]) {
            for (reported in [false, true]) {
                @Expect(matchesNativePluginContributions([PluginContributionDefinition("session", PluginContributionKind.Service,
                    supportsPreparationReference: declared)], [], [], [], services: [PluginServiceDescriptor("session", "",
                    supportsPreparationReference: reported)]), declared == reported)
            }
        }
    }

    @TestCase
    func actualWorkerHandshakeCannotAddOrDropPreparationReferenceSupport(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            for (declared in [false, true]) {
                for (reported in [false, true]) {
                    let source = serviceQuotaFixtureSource().replace("services=[dict(name='session',description='')]",
                        "services=[dict(name='session',description='',supports_preparation_reference=" +
                        if (reported) { "True)]" } else { "False)]" })
                    @Expect(source != serviceQuotaFixtureSource())
                    File.writeTo(root + "/worker", source.toArray())
                    let _ = FileInfo(root + "/worker").setExecutable(true)
                    let actual = startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
                        extensionId: "service-quota", extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
                        contributions: [PluginContributionDefinition("echo", PluginContributionKind.Tool),
                            PluginContributionDefinition("session", PluginContributionKind.Service, supportsPreparationReference: declared)]),
                        ServiceQuotaFixtureLauncher())
                    match (actual) {
                        case JavaScriptHostResult.Ok(host) =>
                            try { @Expect(declared == reported) } finally { let _ = host.awaitCleanup(timeoutMillis: 2000) }
                        case JavaScriptHostResult.Err(error) =>
                            @Expect(declared != reported)
                            @Expect(error.code, "extension.contributions_mismatch")
                            match (error.cleanupHost) { case Some(host) => let _ = host.awaitCleanup(timeoutMillis: 2000); case None => () }
                    }
                }
            }
        } finally { remove(root, recursive: true) }
    }
}
