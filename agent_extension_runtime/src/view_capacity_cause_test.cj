package agent_extension_runtime

import agent_sdk.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

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

func viewOnlyNativeFixture(mode: String): String {
    let root = contentPayloadRoot(mode)
    let worker = contentPayloadWorker()
        .replace("tools=[dict(name='echo',description='',input_schema={})]", "tools=[]")
        .replace("context_providers=[dict(name='context',description='',protocol='axyndra.context-provider/v1')]",
            "views=[dict(name='plan_review',description='View without a Tool or Provider')]")
        .replace("result=f['arguments']",
            "result=dict(schema='axyndra.view/v1',title='View only',summary='Business data',status='ready',interaction='optional',nodes=[dict(id='text',kind='text',text='Actual pure View')],actions=[])")
    File.writeTo(root + "/worker", worker.toArray())
    root
}

func viewOnlyNativeHost(root: String): JavaScriptExtensionHost {
    match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
        extensionId: "content-payload", extensionVersion: "1.0.0",
        profile: JavaScriptHostLaunchProfile.NativeExecutable, contentPayload: true,
        contributions: [PluginContributionDefinition("plan_review", PluginContributionKind.View)]),
        ServiceQuotaFixtureLauncher())) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

@Test
class ViewOnlyNativeBoundaryTests {
    @TestCase
    func actualViewNeedsNeitherFakeToolNorProviderAndCannotAcquireServiceQuota(): Unit {
        let root = viewOnlyNativeFixture("echo")
        let host = viewOnlyNativeHost(root)
        let identity = JavaScriptHostInvocationIdentity(threadId: "actual-view-thread", runId: "", epoch: 0,
            operationId: "", callId: "actual-view-query", kind: "view")
        let query = "{\"schema\":\"axyndra.view-query/v1\",\"context\":{},\"input\":{}}"
        try {
            @Expect(host.tools.isEmpty() && host.policyProviders.isEmpty() && host.contextProviders.isEmpty())
            @Expect(host.views[0].name, "plan_review")
            @Expect(quotaCode(host.invoke("plan_review", query, identity: identity, serviceRequestLimit: 1)),
                "extension.content_provider_not_registered")
            @Expect(!exists(Path(root + "/invoked")))
            let result = match (host.invoke("plan_review", query, identity: identity, serviceRequestLimit: 0)) {
                case JavaScriptHostResult.Ok(value) => value
                case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            try {
                @Expect(!result.isError)
                match (validatePluginViewDocument(parseUnifiedJson(result.resultJson))) {
                    case SdkResult.Ok(_) => ()
                    case SdkResult.Err(error) => @Fail(error.code)
                }
            } finally { result.releasePayload() }
        } finally { @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
    }

    @TestCase
    func actualViewProcessCannotEmitServiceRequestsOrProgressAsAuthority(): Unit {
        for (mode in ["service", "progress"]) {
            let root = viewOnlyNativeFixture(mode); let host = viewOnlyNativeHost(root)
            let identity = JavaScriptHostInvocationIdentity(threadId: "actual-view-thread", runId: "", epoch: 0,
                operationId: "", callId: "actual-view-query", kind: "view")
            try {
                @Expect(quotaCode(host.invoke("plan_review",
                    "{\"schema\":\"axyndra.view-query/v1\",\"context\":{},\"input\":{}}",
                    identity: identity, serviceRequestLimit: 0)), "extension.prepare_effect_forbidden")
                @Expect(host.isClosed)
            } finally { @Expect(host.awaitCleanup(timeoutMillis: 2000).isOk()); remove(root, recursive: true) }
        }
    }
}
