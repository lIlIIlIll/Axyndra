package agent_extension_runtime

import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginContentProviderContractTests {
    @TestCase
    func eitherPureContributionCanInstallWithoutToolsOrCapabilities(): Unit {
        for ((name, kind) in [("context_provider", PluginContributionKind.ContextProvider),
                             ("resource_provider", PluginContributionKind.ResourceProvider)]) {
            let manifest = nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"" + name + "\"")
            @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, manifest)) {
                case PluginPackageResult.Ok(value) => value.contributions.size == 1 &&
                    value.contributions[0].kind == kind && value.requestedCapabilities.isEmpty()
                case PluginPackageResult.Err(_) => false
            })
            @Expect(nativeManifestHasError(manifest.replace("\"capabilities\":[]", "\"capabilities\":[\"process.spawn\"]"),
                "plugin.capability_unsupported", "capabilities"))
        }
    }

    @TestCase
    func queryIdentityRejectsAnyExecutionAuthorityAndRequiresItsOwnNonce(): Unit {
        for (kind in ["context_provider", "resource_provider"]) {
            let value = JavaScriptHostInvocationIdentity(threadId: "thread", runId: "", epoch: 0,
                operationId: "", callId: "query-nonce", kind: kind)
            @Expect(value.runId, "")
            @Expect(value.operationId, "")
            for (bad in ["thread", "nonce", "run", "epoch", "operation", "command"]) {
                @Expect(try {
                    JavaScriptHostInvocationIdentity(threadId: if (bad == "thread") { "" } else { "thread" },
                        runId: if (bad == "run") { "forged-run" } else { "" },
                        epoch: if (bad == "epoch") { 1 } else { 0 },
                        operationId: if (bad == "operation") { "forged-operation" } else { "" },
                        callId: if (bad == "nonce") { "" } else { "query-nonce" },
                        commandId: if (bad == "command") { "forged-command" } else { "" }, kind: kind)
                    false
                } catch (_: IllegalArgumentException) { true })
            }
        }
    }

    @TestCase
    func discoveryRejectsWrongProtocolDuplicateNameAndAuthorityFields(): Unit {
        let declaration = "{\"name\":\"context\",\"description\":\"data\",\"protocol\":\"axyndra.context-provider/v1\"}"
        for (raw in ["null", "[" + declaration + "," + declaration + "]",
                     "[" + declaration.replace("context-provider", "resource-provider") + "]",
                     "[" + declaration.replace("\"description\":\"data\"", "\"description\":false") + "]",
                     "[" + declaration.replace("\"description\":\"data\"", "\"description\":\"data\",\"trust\":\"system\"") + "]"]) {
            @Expect(match (parsePluginContentProviders(parseUnifiedJson("{\"context_providers\":" + raw + "}"), false)) {
                case JavaScriptHostResult.Err(_) => true; case _ => false
            })
        }
        @Expect(match (parsePluginContentProviders(parseUnifiedJson("{\"context_providers\":[" + declaration + "]}"), false)) {
            case JavaScriptHostResult.Ok(value) => value.size == 1 && value[0].name == "context"
            case _ => false
        })
    }

    @TestCase
    func discoveryRejectsThirtyThreeDeclarationsBeforePublication(): Unit {
        var declarations = ""
        for (index in 0..33) {
            if (index > 0) { declarations += "," }
            declarations += "{\"name\":\"resource-" + index.toString() + "\",\"description\":\"data\",\"protocol\":\"axyndra.resource-provider/v1\"}"
        }
        @Expect(match (parsePluginContentProviders(parseUnifiedJson("{\"resource_providers\":[" + declarations + "]}"), true)) {
            case JavaScriptHostResult.Err(error) => error.code == "extension.content_providers_invalid"
            case _ => false
        })
    }
}
