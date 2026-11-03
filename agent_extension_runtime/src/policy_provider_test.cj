package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import process4cj.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func policyProviderFixture(mode: String): String {
    let root = contentPayloadRoot(mode)
    let source = contentPayloadWorker().replace("context_providers", "providers")
        .replace("axyndra.context-provider/v1", "axyndra.policy-provider/v1")
        .replace("tools=[dict(name='echo',description='',input_schema={})]", "tools=[]")
    File.writeTo(root + "/worker", source.toArray())
    root
}
func policyProviderHost(root: String): JavaScriptExtensionHost {
    match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
        extensionId: "content-payload", extensionVersion: "1.0.0", profile: JavaScriptHostLaunchProfile.NativeExecutable,
        contentPayload: true, contributions: [PluginContributionDefinition("context", PluginContributionKind.Provider)]),
        ServiceQuotaFixtureLauncher())) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
}
func policyProviderIdentity(): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(threadId: "policy-thread", runId: "", epoch: 0,
        operationId: "", callId: "actual-policy-query", kind: "provider")
}

@Test
class PluginPolicyProviderTests {
    @TestCase
    func manifestUsesExistingProviderKindWithoutInventingToolOrCapability(): Unit {
        let manifest = nativeCommandManifest().replace("\"kind\":\"command\"", "\"kind\":\"provider\"")
        @Expect(match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, manifest)) {
            case PluginPackageResult.Ok(value) => value.contributions.size == 1 &&
                value.contributions[0].kind == PluginContributionKind.Provider && value.requestedCapabilities.isEmpty()
            case _ => false })
        @Expect(nativeManifestHasError(manifest.replace("\"capabilities\":[]", "\"capabilities\":[\"process.spawn\"]"),
            "plugin.capability_unsupported", "capabilities"))
    }

    @TestCase
    func policyIdentityCannotContainExecutionAuthority(): Unit {
        let _ = policyProviderIdentity()
        for (field in ["run", "operation", "epoch", "command"]) {
            @Expect(try {
                JavaScriptHostInvocationIdentity(threadId: "thread", runId: if (field == "run") { "forged" } else { "" },
                    epoch: if (field == "epoch") { 1 } else { 0 }, operationId: if (field == "operation") { "forged" } else { "" },
                    callId: "nonce", commandId: if (field == "command") { "forged" } else { "" }, kind: "provider")
                false
            } catch (_: IllegalArgumentException) { true })
        }
    }

    @TestCase
    func metadataMustUseExactPureProtocolAndNoAuthorityFields(): Unit {
        let row = "{\"name\":\"rank\",\"description\":\"data\",\"protocol\":\"axyndra.policy-provider/v1\"}"
        for (bad in [row.replace("policy-provider", "context-provider"), row + "," + row,
            row.replace("\"description\":\"data\"", "\"description\":\"data\",\"authority\":true")]) {
            @Expect(!parsePluginPolicyProviders(parseUnifiedJson("{\"providers\":[" + bad + "]}")).isOk())
        }
        @Expect(parsePluginPolicyProviders(parseUnifiedJson("{\"providers\":[" + row + "]}")).isOk())
    }

    @TestCase
    func actualProviderOnlyProcessPreservesLargeDataAndReleasesItsOwnerCharge(): Unit {
        let root = policyProviderFixture("echo"); let host = policyProviderHost(root)
        let baseline = nativePayloadOwnerBudget.usage()
        try {
            @Expect(host.tools.isEmpty() && host.contextProviders.isEmpty() && host.policyProviders.size == 1)
            let text = String.fromUtf8(Array<Byte>(1048576, repeat: b'p'))
            let result = match (host.invoke("context", stringifyUnifiedJson(objectValue([ValueField("text", textValue(text))])),
                identity: policyProviderIdentity(), serviceRequestLimit: 0)) {
                case JavaScriptHostResult.Ok(value) => value
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code) }
            try {
                @Expect(parseUnifiedJson(result.resultJson, maxBytes: CONTENT_PAYLOAD_RESULT_BYTES).field("text").getOrThrow().text, text)
                @Expect(nativePayloadOwnerBudget.usage()[0] > baseline[0])
            } finally { result.releasePayload() }
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), baseline))
        } finally { let _ = host.awaitCleanup(timeoutMillis: 2000); remove(root, recursive: true) }
    }

    @TestCase
    func actualPolicyCannotRequestServicesProgressOrUnboundedDenseData(): Unit {
        for (mode in ["service", "progress", "dense", "wrong_window"]) {
            let root = policyProviderFixture(mode)
            // The host owns a fixed reader buffer until actual cleanup ACK.
            // Compare post-close usage to the state before admitting that owner.
            let baseline = nativePayloadOwnerBudget.usage()
            let host = policyProviderHost(root)
            try {
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(), (baseline[0] + 1, baseline[1] + 8192)))
                @Expect(!host.invoke("context", "{}", identity: policyProviderIdentity(), serviceRequestLimit: 0).isOk())
                @Expect(host.isClosed)
            } finally { @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
            let released = nativePayloadOwnerBudget.usage()
            @Expect(released[0], baseline[0])
            @Expect(released[1], baseline[1])
        }
    }
}
