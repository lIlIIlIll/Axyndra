package agent_extension_runtime

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

func nativeCommandManifest(): String {
    "{\"id\":\"native-command\",\"version\":\"1.0.0\",\"entry_kind\":\"native-executable\",\"entrypoint\":\"bin/plugin\",\"sdk_range\":\"[2.0.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\",\"capabilities\":[],\"contributions\":[{\"kind\":\"command\",\"name\":\"hello\"}]}"
}

func nativeManifestHasError(document: String, code: String, field: String): Bool {
    match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, document, source: "fixture:manifest")) {
        case PluginPackageResult.Err(error) =>
            error.code == code && error.field == field && error.source == "fixture:manifest"
        case PluginPackageResult.Ok(_) => false
    }
}

@Test
class NativePluginContractTests {
    @TestCase
    func serviceDeclarationsRejectAmbiguityAndUnboundedLists(): Unit {
        let valid = "{\"name\":\"session\",\"description\":\"bounded service\"}"
        for ((declarations, code) in [
            ("[" + valid + "," + valid + "]", "extension.service_duplicate"),
            ("[{\"name\":\"session\",\"description\":\"x\",\"extra\":true}]", "extension.service_invalid"),
            ("[{\"name\":17,\"description\":\"x\"}]", "extension.service_invalid"),
            ("[{\"name\":\"session\",\"description\":false}]", "extension.service_invalid"),
            ("[{\"name\":\"session\"}]", "extension.service_invalid"),
            ("null", "extension.services_invalid")
        ]) {
            @Expect(match (parsePluginServices(parseUnifiedJson("{\"services\":" + declarations + "}"))) {
                case JavaScriptHostResult.Err(error) => error.code == code
                case JavaScriptHostResult.Ok(_) => false
            })
        }
        var oversized = "["
        for (index in 0..65) {
            if (index > 0) { oversized += "," }
            oversized += "{\"name\":\"service-" + index.toString() + "\",\"description\":\"x\"}"
        }
        oversized += "]"
        @Expect(match (parsePluginServices(parseUnifiedJson("{\"services\":" + oversized + "}"))) {
            case JavaScriptHostResult.Err(error) => error.code == "extension.services_invalid"
            case JavaScriptHostResult.Ok(_) => false
        })
    }

    @TestCase
    func serviceOnlyManifestDoesNotNeedAToolOrGrantProcessAuthority(): Unit {
        let manifest = nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"service\"")
        @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, manifest)) {
            case PluginPackageResult.Ok(value) => value.contributions.size == 1 &&
                value.contributions[0].kind == PluginContributionKind.Service && value.requestedCapabilities.isEmpty()
            case PluginPackageResult.Err(_) => false
        })
        @Expect(nativeManifestHasError(manifest.replace("\"capabilities\":[]", "\"capabilities\":[\"process.spawn\"]"),
            "plugin.capability_unsupported", "capabilities"))
    }

    @TestCase
    func serviceIdentityRequiresCanonicalOperationUnlikeOfflineCommand(): Unit {
        let identity = JavaScriptHostInvocationIdentity(threadId: "maintenance-thread", runId: "maintenance-run",
            epoch: 1, operationId: "operation", callId: "call", kind: "service")
        @Expect(identity.threadId, "maintenance-thread")
        for (bad in ["thread", "run", "epoch", "operation", "call", "command"]) {
            let rejected = try {
                JavaScriptHostInvocationIdentity(threadId: if (bad == "thread") { "" } else { "thread" },
                    runId: if (bad == "run") { "" } else { "run" }, epoch: if (bad == "epoch") { 0 } else { 1 },
                    operationId: if (bad == "operation") { "" } else { "operation" },
                    callId: if (bad == "call") { "" } else { "call" },
                    commandId: if (bad == "command") { "forged" } else { "" }, kind: "service")
                false
            } catch (_: IllegalArgumentException) { true }
            @Expect(rejected)
        }
    }

    @TestCase
    func prepareIdentityRequiresCanonicalRunWithoutOperationAuthority(): Unit {
        let identity = JavaScriptHostInvocationIdentity(threadId: "thread", runId: "run",
            epoch: 1, operationId: "", callId: "call", kind: "prepare")
        @Expect(identity.kind, "prepare")
        @Expect(identity.operationId, "")
        @Expect(identity.commandId, "")
        for (invalidField in ["thread", "run", "epoch", "call", "operation", "command"]) {
            let rejected = try {
                JavaScriptHostInvocationIdentity(
                    threadId: if (invalidField == "thread") { "" } else { "thread" },
                    runId: if (invalidField == "run") { "" } else { "run" },
                    epoch: if (invalidField == "epoch") { 0 } else { 1 },
                    callId: if (invalidField == "call") { "" } else { "call" },
                    operationId: if (invalidField == "operation") { "forged-operation" } else { "" },
                    commandId: if (invalidField == "command") { "forged-command" } else { "" },
                    kind: "prepare"
                )
                false
            } catch (_: IllegalArgumentException) { true }
            @Expect(rejected)
        }
    }

    @TestCase
    func commandOnlyPackageRetainsContributionAndEntryIdentity(): Unit {
        @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, nativeCommandManifest())) {
            case PluginPackageResult.Ok(value) =>
                let diagnostic = pluginPackageDiagnosticValue(value)
                value.entryKind == PluginEntryKind.NativeExecutable &&
                value.entrypoint == "bin/plugin" && value.compatibilityProfile == "axyndra-native-v2" &&
                value.namespace == "axyndra:native-command" && value.contributions.size == 1 &&
                value.contributions[0].kind == PluginContributionKind.Command &&
                value.contributions[0].name == "hello" &&
                textField(diagnostic, "entry_kind") == "native-executable" &&
                textField(diagnostic, "host_sdk_version") == AGENT_SDK_VERSION &&
                !boolField(diagnostic, "signature_declared") &&
                !hasField(diagnostic, "signature")
            case PluginPackageResult.Err(_) => false
        })
    }

    @TestCase
    func viewOnlyPackageRetainsItsKindInTheNoToolContract(): Unit {
        let document = nativeCommandManifest()
            .replace("[{\"kind\":\"command\",\"name\":\"hello\"}]",
                "[{\"kind\":\"view\",\"name\":\"plan-review\"}]")
            .replace("native-command", "native-view")
        let accepted = match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, document)) {
            case PluginPackageResult.Ok(value) =>
                let diagnostic = pluginPackageDiagnosticValue(value)
                let contributions = match (diagnostic.field("contributions")) {
                    case Some(items) => items
                    case None => return @Expect(false)
                }
                value.contributions.size == 1 &&
                value.contributions[0].kind == PluginContributionKind.View &&
                value.contributions[0].name == "plan-review" &&
                contributions.items.size == 1 &&
                textField(contributions.items[0], "kind") == "view" &&
                textField(contributions.items[0], "identity") == "axyndra:native-view/view/plan-review"
            case PluginPackageResult.Err(_) => false
        }
        @Expect(accepted)
        @Expect(nativeManifestHasError(document.replace("\"plan-review\"", "\"Bad Name\""),
            "plugin.contribution_name_invalid", "contributions.name"))
    }

    @TestCase
    func nativeCompatibilityRejectsUnknownPortsAndVersionsBeforeLaunch(): Unit {
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("axyndra-js-host-v2", "unknown-v3"),
            "plugin.protocol_unsupported", "protocol_range"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("[2.0.0,3.0.0)", "[3.0.0,4.0.0)"),
            "plugin.sdk_incompatible", "sdk_range"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("[2.0.0,3.0.0)", "2.x"),
            "plugin.sdk_range_malformed", "sdk_range"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("[2.0.0,3.0.0)", "[3.0.0,2.0.0)"),
            "plugin.sdk_range_malformed", "sdk_range"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("1.0.0", "latest"),
            "plugin.version_malformed", "version"))
        for (kind in ["skill", "event", "unknown"]) {
            @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"" + kind + "\""),
                "plugin.contribution_unsupported", "contributions.kind"))
        }
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"capabilities\":[]", "\"capabilities\":[\"process.spawn\"]"),
            "plugin.capability_unsupported", "capabilities"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("bin/plugin", "C:/plugin"),
            "plugin.entrypoint_escape", "entrypoint"))
    }

    @TestCase
    func legacyCapabilityResourcesRemainInspectableWithoutRelaxingPaths(): Unit {
        let legacy = "{\"id\":\"legacy\",\"version\":\"1.0.0\",\"entrypoint\":\"plugin.sh\",\"capabilities\":[\"workspace.read\",\"network.access:api.example.test:443\"]}"
        @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, legacy)) {
            case PluginPackageResult.Ok(value) =>
                value.entryKind == PluginEntryKind.LegacyProcess &&
                value.requestedCapabilities == ["workspace.read", "network.access:api.example.test:443"]
            case PluginPackageResult.Err(_) => false
        })
        @Expect(nativeManifestHasError(legacy.replace("plugin.sh", "C:/escape/plugin.sh"),
            "plugin.entrypoint_escape", "entrypoint"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"capabilities\":[]",
            "\"capabilities\":[\"network.access:api.example.test:443\"]"),
            "plugin.capability_unsupported", "capabilities"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace("\"capabilities\":[]",
            "\"capabilities\":[17]"), "plugin.capability_list_invalid", "capabilities"))
    }

    @TestCase
    func nativeDeclarationsRejectDuplicateIdentities(): Unit {
        @Expect(nativeManifestHasError(nativeCommandManifest().replace(
            "[{\"kind\":\"command\",\"name\":\"hello\"}]",
            "[{\"kind\":\"command\",\"name\":\"hello\"},{\"kind\":\"command\",\"name\":\"hello\"}]"),
            "plugin.contribution_duplicate", "contributions"))
        @Expect(nativeManifestHasError(nativeCommandManifest().replace(
            "[{\"kind\":\"command\",\"name\":\"hello\"}]", "[]"),
            "plugin.contributions_invalid", "contributions"))
    }

    @TestCase
    func nativeLaunchUsesPackagedExecutableAndBoundedProcessContract(): Unit {
        let request = JavaScriptHostLaunchRequest("/fixture/native", "bin/plugin",
            profile: JavaScriptHostLaunchProfile.NativeExecutable,
            extensionId: "native-command", extensionVersion: "1.0.0",
            contributions: [PluginContributionDefinition("hello", PluginContributionKind.Command)])
        let command = pluginHostProcessCommand(request, "/fixture/native")
        @Expect(command.executable, "/fixture/native/bin/plugin")
        @Expect(command.arguments.isEmpty())
        @Expect(command.workingDirectory, "/fixture/native")
        @Expect(command.maxOutputBytes, JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES * 4)
        @Expect(command.terminateProcessTree)
        @Expect(command.environment.size, 3)
        @Expect(!validIsolatedPluginEntrypoint("../escape"))
        @Expect(!validIsolatedPluginEntrypoint("C:/escape"))
        @Expect(validIsolatedPluginEntrypoint("bin/plugin"))
    }

    @TestCase
    func handshakeBindsTypedDeclarationsWithoutInventingATool(): Unit {
        let declared = [PluginContributionDefinition("hello", PluginContributionKind.Command)]
        @Expect(matchesNativePluginContributions(declared, [], [JavaScriptCommandDescriptor("hello")], []))
        @Expect(!matchesNativePluginContributions(declared, [JavaScriptToolDescriptor("hello")], [], []))
        @Expect(!matchesNativePluginContributions(declared, [], [JavaScriptCommandDescriptor("other")], []))
        @Expect(!matchesNativePluginContributions(declared, [], [JavaScriptCommandDescriptor("hello")],
            [JavaScriptHookDescriptor("tool_call", 0)]))
        @Expect(!matchesNativePluginContributions(declared, [JavaScriptToolDescriptor("extra")],
            [JavaScriptCommandDescriptor("hello")], []))
    }
}
