package agent_extension_runtime

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import yjson_support.*

@Test
class PluginPackageContractTests {
    @TestCase
    func piManifestKeepsComponentBoundaries(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"pi-safe\",\"version\":\"1.2.3\",\"pi\":{\"skills\":[\"skills\"],\"prompts\":[\"prompts\"],\"extensions\":[\"dist/plugin.js\"],\"themes\":[\"theme.json\"]}}",
            source: "local:/fixture/pi-safe"
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.id == "pi-safe" && value.version == "1.2.3" &&
                value.ecosystem == PluginEcosystem.Pi &&
                value.entrypoint == "dist/plugin.js" &&
                value.components.size == 4 &&
                value.components[0].kind == PluginComponentKind.Skill &&
                value.components[1].kind == PluginComponentKind.Prompt &&
                value.components[2].kind == PluginComponentKind.Extension &&
                value.components[3].kind == PluginComponentKind.Theme
            case PluginPackageResult.Err(_) => false
        })
    }
    @TestCase
    func piManifestCapabilityOverlayIsExplicitAndBounded(): Unit {
        let requested = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"pi-service\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"service.js\"],\"axyndra\":{\"capabilities\":[\"workspace.read\",\"workspace.write\"]}}}",
            source: "local:/fixture/pi-service"
        )
        @Expect(match (requested) {
            case PluginPackageResult.Ok(value) =>
                value.entrypoint == "service.js" &&
                value.requestedCapabilities == ["workspace.read", "workspace.write"]
            case PluginPackageResult.Err(_) => false
        })
        let widened = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"pi-service\",\"version\":\"1.0.0\",\"pi\":{\"axyndra\":{\"capabilities\":[\"process.spawn\"]}}}",
            source: "local:/fixture/pi-service"
        )
        @Expect(match (widened) {
            case PluginPackageResult.Err(error) =>
                error.code == "plugin.capability_unsupported"
            case PluginPackageResult.Ok(_) => false
        })
        let malformed = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"pi-service\",\"version\":\"1.0.0\",\"pi\":{\"axyndra\":{\"capabilities\":\"workspace.read\"}}}",
            source: "local:/fixture/pi-service"
        )
        @Expect(match (malformed) {
            case PluginPackageResult.Err(error) =>
                error.code == "plugin.capability_list_invalid"
            case PluginPackageResult.Ok(_) => false
        })
    }

    @TestCase
    func codexHostedOnlyMappingIsBlocked(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Codex,
            "{\"name\":\"codex-safe\",\"version\":\"2.0.0\",\"app\":{\"id\":\"vendor-only\"}}",
            source: "local:/fixture/codex-safe"
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.ecosystem == PluginEcosystem.Codex &&
                value.components.size == 1 &&
                value.components[0].kind == PluginComponentKind.HostedOnly &&
                value.components[0].status == PluginComponentStatus.Blocked
            case PluginPackageResult.Err(_) => false
        })
    }

    @TestCase
    func extensionManifestRejectsUnsafeEntrypointAndUnboundedCapability(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Axyndra,
            "{\"id\":\"unsafe\",\"version\":\"1.0.0\",\"entrypoint\":\"../escape\",\"capabilities\":[\"ambient\"]}",
            source: "local:/fixture/unsafe"
        )
        @Expect(match (result) {
            case PluginPackageResult.Err(error) =>
                error.code == "plugin.entrypoint_escape"
            case PluginPackageResult.Ok(_) => false
        })
    }
    @TestCase
    func piComponentPathsCannotEscapePackageRoot(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"escape\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"../outside\"]}}",
            source: "local:fixture/escape"
        )
        @Expect(match (result) {
            case PluginPackageResult.Err(error) =>
                error.code == "plugin.component_path_invalid" && error.field == "skills"
            case PluginPackageResult.Ok(_) => false
        })
    }

    @TestCase
    func codexPortableMcpMappingIsSupported(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Codex,
            "{\"name\":\"codex-mcp\",\"version\":\"1.0.0\",\"mcp\":{\"servers\":{\"local\":{\"command\":\"node\"}}}}",
            source: "local:/fixture/codex-mcp"
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.components.size == 1 &&
                value.components[0].kind == PluginComponentKind.Mcp &&
                value.components[0].status == PluginComponentStatus.Supported
            case PluginPackageResult.Err(_) => false
        })
    }
    @TestCase
    func codexInlineCommandHooksExposeOnlySelectedEvents(): Unit {
        let document = "{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"printf pre\",\"timeout\":1}]}],\"PostToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"printf post\"}]}]}"
        let parsed = try {
            parseUnifiedJson(document, maxBytes: 1048576, maxDepth: 32)
        } catch (error: Exception) {
            throw IllegalArgumentException(error.message)
        }
        let hooks = parsed
        let components = ArrayList<PluginComponent>()
        let result = pluginCodexHookConfiguration(
            "", hooks, "fixture#hooks", components
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.size == 2 &&
                value[0].event == "PreToolUse" &&
                value[0].matcher == "Bash" &&
                value[0].timeoutMillis == 1000 &&
                value[1].event == "PostToolUse" &&
                value[1].matcher == "*" &&
                value[1].timeoutMillis == 2000 &&
                components.size == 1 &&
                components[0].status == PluginComponentStatus.Supported
            case PluginPackageResult.Err(_) => false
        })
    }

    @TestCase
    func codexManifestWithNoImplementedHookEventIsBlocked(): Unit {
        let document = "{\"Notification\":[]}"
        let parsed = try {
            parseUnifiedJson(document, maxBytes: 1048576, maxDepth: 32)
        } catch (error: Exception) {
            throw IllegalArgumentException(error.message)
        }
        let hooks = parsed
        let components = ArrayList<PluginComponent>()
        let result = pluginCodexHookConfiguration(
            "", hooks, "fixture#hooks", components
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.isEmpty() &&
                components.size == 1 &&
                components[0].kind == PluginComponentKind.Hook &&
                components[0].status == PluginComponentStatus.Blocked
            case PluginPackageResult.Err(_) => false
        })
    }
    @TestCase
    func unsupportedHooksAndCommandsAreDiagnosed(): Unit {
        let result = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"pi-blocked\",\"version\":\"1.0.0\",\"pi\":{\"hooks\":[\"hooks\"],\"commands\":[\"commands\"],\"themes\":[\"themes\"]}}",
            source: "local:/fixture/pi-blocked"
        )
        @Expect(match (result) {
            case PluginPackageResult.Ok(value) =>
                value.components.size == 3 &&
                value.components[0].kind == PluginComponentKind.Theme &&
                value.components[0].status == PluginComponentStatus.Blocked &&
                value.components[1].kind == PluginComponentKind.Hook &&
                value.components[1].status == PluginComponentStatus.Blocked &&
                value.components[2].kind == PluginComponentKind.Command &&
                value.components[2].status == PluginComponentStatus.Blocked
            case PluginPackageResult.Err(_) => false
        })
    }

    @TestCase
    func piSelectorsRejectTraversalAndUnsupportedGlobForms(): Unit {
        for (selector in ["!../outside", "skills/[private]"]) {
            let result = parsePluginPackageManifest(
                PluginManifestFamily.Pi,
                "{\"name\":\"invalid-selector\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"" + selector + "\"]}}",
                source: "local:/fixture/invalid-selector"
            )
            @Expect(match (result) {
                case PluginPackageResult.Err(error) =>
                    error.code == "plugin.component_selector_invalid" && error.field == "skills"
                case PluginPackageResult.Ok(_) => false
            })
        }
    }

    @TestCase
    func piSelectorsEnforceLengthAndCountBudgets(): Unit {
        let longSelector = String.fromUtf8(Array<Byte>(257, repeat: 97))
        let longResult = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"long-selector\",\"version\":\"1.0.0\",\"pi\":{\"skills\":\"" + longSelector + "\"}}",
            source: "local:/fixture/long-selector"
        )
        @Expect(match (longResult) {
            case PluginPackageResult.Err(error) => error.code == "plugin.component_selector_limit"
            case PluginPackageResult.Ok(_) => false
        })
        var selectors = "["
        for (index in 0..129) {
            if (index > 0) { selectors += "," }
            selectors += "\"skills\""
        }
        selectors += "]"
        let listResult = parsePluginPackageManifest(
            PluginManifestFamily.Pi,
            "{\"name\":\"many-selectors\",\"version\":\"1.0.0\",\"pi\":{\"skills\": " + selectors + "}}",
            source: "local:/fixture/many-selectors"
        )
        @Expect(match (listResult) {
            case PluginPackageResult.Err(error) => error.code == "plugin.component_selector_limit"
            case PluginPackageResult.Ok(_) => false
        })
    }
}
