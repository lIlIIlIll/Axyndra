package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These exercise real isolated C workers and immutable operator files. The
// contexts are host-test inputs, not proof of canonical lifecycle admission;
// the manager's Store/approval/lease contracts remain a separate obligation.
class PinnedServiceFixture {
    let files = LifecycleConfigurationFixture()
    let host: ProductJavaScriptPluginHost
    let record: ProductPluginRecord
    let mountGeneration: UInt64
    let config: ProductPluginLifecycleConfiguration
    let grant: ProductPluginLifecycleLaunchGrant
    let configurationText: String
    let cancellation = CancellationSource()
    var endpoint: ?ProductPinnedNativeServiceEndpoint = None
    private let registryOwners = ProductRegistryTestOwners()

    init(capacityProfile!: ?AgentValue = None, lifetimeMillis!: Int64 = 60000) {
        host = ProductJavaScriptPluginHost(settingsRoot: files.settings)
        try {
        let binary = canonicalize(Path(getVariable("AXYNDRA_NATIVE_SERVICE_PLUGIN_FIXTURE").getOrThrow()))
        let source = files.root + "/native-service-source"
        Directory.create(source)
        pluginCopySnapshotTreeSecure(binary.parent.toString(), source)
        File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
            ValueField("id", textValue("pinned-service-fixture")), ValueField("version", textValue("1.0.0")),
            ValueField("entrypoint", textValue(binary.fileName)), ValueField("entry_kind", textValue("native-executable")),
            ValueField("sdk_range", textValue("[2.0.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
            ValueField("contributions", listValue([objectValue([
                ValueField("kind", textValue("service")), ValueField("name", textValue("session"))])]))
        ])).toArray())
        let registry = registryOwners.openProduct(files.settings, files.workspace)
        lifecycleTestRequire(host.ownRegistry(registry))
        let imported = match (registry.importLocal(source)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        imported.close()
        record = match (registry.setEnabled("axyndra:pinned-service-fixture", true)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        let _ = lifecycleTestRequire(host.mount(record))
        mountGeneration = host.instanceGeneration(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))
        let service = files.service()
        service.put("executable", textValue("/bin/true"))
        service.put("arguments", listValue([]))
        service.put("lifetime_ms", integerValue(lifetimeMillis))
        match (capacityProfile) { case Some(value) => service.put("protocol_limits", value); case None => () }
        let document = files.document(service: Some(service))
        let plugin = document.field("plugins").getOrThrow().items[0]
        plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
        plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
        files.write(document)
        configurationText = stringifyUnifiedJson(document)
        config = lifecycleTestRequire(loadPluginLifecycleConfiguration(files.settings, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),
            productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))))
        let bindingContext = ToolInvocationContext(RunId("service-run-binding"), SessionId("target-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)]),
            epoch: 7, cancellation: cancellation.token,
            toolContext: ToolContextDescriptor(workspaceRoot: files.workspace, cwd: files.workspace))
        grant = lifecycleTestRequire(host.bindLifecycleService(config, "stdio", ThreadId("target-thread"),
            files.workspace, ExecutionResourceLimits(), pluginInvocationAuthorityScope(bindingContext), mountGeneration))
        } catch (error: Exception) {
            try { let _ = host.close() } finally { cancellation.close(); registryOwners.close(); files.close() }
            throw error
        }
    }

    func context(thread: String, sequence: String, restricted!: Bool = false,
        environment!: ToolEnvironmentView = ToolEnvironmentView()): ToolInvocationContext {
        ToolInvocationContext(RunId("service-run-" + sequence), SessionId(thread),
            CapabilitySet(values: if (restricted) { [Capability(CapabilityKind.ProcessSpawn)] }
                else { [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke)] }),
            epoch: 7, cancellation: cancellation.token,
            toolContext: ToolContextDescriptor(workspaceRoot: files.workspace, cwd: files.workspace, environment: environment))
    }
    func identity(context: ToolInvocationContext, sequence: String, prepare!: Bool = false): JavaScriptHostInvocationIdentity {
        JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value, epoch: context.epoch,
            operationId: if (prepare) { "" } else { "service-operation-" + sequence },
            callId: "service-call-" + sequence, kind: if (prepare) { "service_prepare" } else { "service" })
    }
    func pin(): ProductPinnedNativeServiceEndpoint {
        match (host.pinServiceEndpoint(grant, context("target-thread", "pin"),
            ThreadId("maintenance-thread"), "session", mountGeneration)) {
            case ProductServiceEndpointSelection.Ready(selected) => endpoint = Some(selected); selected
            case ProductServiceEndpointSelection.Rejected(error) => throw IllegalStateException(error.code)
            case ProductServiceEndpointSelection.CleanupRequired(selected, original, cleanup) =>
                endpoint = Some(selected)
                throw IllegalStateException(original.code + ": " + cleanup.code)
        }
    }
    func call(selected: ProductPinnedNativeServiceEndpoint, thread: String, sequence: String,
        arguments!: String = "{}"): Result<ProductJavaScriptPluginInvocationResult> {
        let current = context(thread, sequence)
        host.invokeService(selected, arguments, identity(current, sequence), current)
    }
    func close(): Unit {
        cancellation.cancel()
        try {
            match (endpoint) { case Some(value) => let _ = host.closeServiceEndpoint(value, timeoutMillis: 2000); case None => () }
        } finally {
            cancellation.close()
            try { let _ = host.close() } finally { registryOwners.close(); files.close() }
        }
    }
}

func pinnedCode<T>(result: Result<T>): String {
    match (result) { case Result.Err(error) => error.code; case Result.Ok(_) => "unexpected-success" }
}
func selectionCode(result: ProductServiceEndpointSelection): String {
    match (result) {
        case ProductServiceEndpointSelection.Rejected(error) => error.code
        case ProductServiceEndpointSelection.Ready(endpoint) => let _ = endpoint.close(); "unexpected-success"
        case ProductServiceEndpointSelection.CleanupRequired(endpoint, original, cleanup) =>
            let _ = endpoint.close(timeoutMillis: 2000)
            "unexpected-cleanup-owner:" + original.code + ":" + cleanup.code
    }
}
func pinnedCalls(result: Result<ProductJavaScriptPluginInvocationResult>): String {
    lifecycleTestRequire(result).value.field("calls").getOrThrow().asNumberText()
}

class PinnedServiceBlockingObserver <: JavaScriptHostObserver {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    public func onProgress(_: String, _: String): JavaScriptHostResult<Unit> { JavaScriptHostResult.Ok(()) }
    public func onServiceRequest(_: String, _: String, _: String, _: String): JavaScriptHostResult<String> {
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        JavaScriptHostResult.Err(JavaScriptHostError("fixture.no_authority", "test observer grants no host service"))
    }
}

@Test
class PinnedNativeServiceEndpointTests {
    @TestCase
    func preparationMaintenanceAndTargetCallsKeepOneExactWorker(): Unit {
        let fixture = PinnedServiceFixture()
        try {
            let endpoint = fixture.pin()
            let preparation = fixture.context("target-thread", "prepare")
            let prepared = lifecycleTestRequire(fixture.host.prepareService(endpoint, "{}",
                fixture.identity(preparation, "prepare", prepare: true), preparation))
            @Expect(prepared.isError, false)
            @Expect(prepared.value.field("prepared").getOrThrow().asBool(), true)
            @Expect(pinnedCalls(fixture.call(endpoint, "maintenance-thread", "start")), "1")
            @Expect(pinnedCalls(fixture.call(endpoint, "target-thread", "tool")), "2")
            let noAuthority = lifecycleTestRequire(fixture.call(endpoint, "target-thread", "no-observer",
                arguments: "{\"mode\":\"service_read\"}"))
            @Expect(noAuthority.isError, true)
            @Expect(stringifyUnifiedJson(noAuthority.value).contains("extension.service_unsupported"), true)
            let ordinary = fixture.context("target-thread", "ordinary")
            @Expect(pinnedCode(fixture.host.invoke(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "session", "{}",
                identity: fixture.identity(ordinary, "ordinary"), cancellation: ordinary.cancellation)),
                "plugin.service_endpoint_required")
            @Expect(pinnedCalls(fixture.call(endpoint, "target-thread", "still-same")), "4")
            @Expect(fixture.host.closeServiceEndpoint(endpoint).isOk(), true)
            @Expect(fixture.host.closeServiceEndpoint(endpoint).isOk(), true)
        } finally { fixture.close() }
    }

    @TestCase
    func foreignHostThreadPermissionDomainAndEnvelopeCannotBorrowEndpoint(): Unit {
        let fixture = PinnedServiceFixture()
        let other = ProductJavaScriptPluginHost()
        try {
            let endpoint = fixture.pin()
            let proper = fixture.context("target-thread", "proper")
            @Expect(pinnedCode(other.invokeService(endpoint, "{}", fixture.identity(proper, "proper"), proper)),
                "plugin.service_endpoint_foreign")
            for (context in [fixture.context("foreign-thread", "foreign"),
                fixture.context("target-thread", "less", restricted: true),
                fixture.context("maintenance-thread", "less-maintenance", restricted: true),
                fixture.context("target-thread", "env", environment: ToolEnvironmentView(entries: [ToolEnvironmentEntry("MODE", "other")]))]) {
                @Expect(pinnedCode(fixture.host.invokeService(endpoint, "{}", fixture.identity(context, "scope"), context)),
                    "plugin.service_scope_mismatch")
            }
            @Expect(pinnedCode(fixture.host.invokeService(endpoint, "{}",
                fixture.identity(fixture.context("target-thread", "wrong-run"), "bad"), proper)), "plugin.service_scope_mismatch")
            @Expect(pinnedCalls(fixture.call(endpoint, "target-thread", "first-real")), "1")
        } finally { let _ = other.close(); fixture.close() }
    }

    @TestCase
    func protocolFailureNeverRespawnsOldSelector(): Unit {
        let fixture = PinnedServiceFixture()
        try {
            let old = fixture.pin()
            let context = fixture.context("target-thread", "bad-prepare")
            @Expect(pinnedCode(fixture.host.prepareService(old, "{\"mode\":\"prepare_wrong_operation\"}",
                fixture.identity(context, "bad-prepare", prepare: true), context)), "extension.protocol_identity_mismatch")
            @Expect(pinnedCode(fixture.call(old, "target-thread", "after-failure")), "plugin.service_endpoint_stale")
            @Expect(fixture.host.closeServiceEndpoint(old, timeoutMillis: 2000).isOk(), true)
            let replacement = fixture.pin()
            @Expect(old.endpointIdentity != replacement.endpointIdentity, true)
            @Expect(old.workerGeneration < replacement.workerGeneration, true)
            @Expect(pinnedCalls(fixture.call(replacement, "target-thread", "fresh")), "1")
            @Expect(pinnedCode(fixture.call(old, "target-thread", "never-retarget")), "plugin.service_endpoint_stale")
        } finally { fixture.close() }
    }

    @TestCase
    func configRevocationPersistsAfterRestoringBytesUntilExplicitNewSelection(): Unit {
        let fixture = PinnedServiceFixture()
        try {
            let old = fixture.pin()
            File.writeTo(fixture.files.settings + "/plugins/lifecycle.json", "{\"version\":1,\"plugins\":[]}".toArray())
            @Expect(pinnedCode(fixture.call(old, "target-thread", "revoked")), "plugin.lifecycle_configuration_changed")
            File.writeTo(fixture.files.settings + "/plugins/lifecycle.json", fixture.configurationText.toArray())
            @Expect(pinnedCode(fixture.call(old, "target-thread", "restored")), "plugin.service_endpoint_stale")
            @Expect(fixture.host.closeServiceEndpoint(old).isOk(), true)
            let replacement = fixture.pin()
            @Expect(replacement.endpointIdentity != old.endpointIdentity, true)
            @Expect(pinnedCalls(fixture.call(replacement, "target-thread", "fresh")), "1")
        } finally { fixture.close() }
    }

    @TestCase
    func disableAndSamePackageRemountCannotReuseGrantOrSelector(): Unit {
        let fixture = PinnedServiceFixture()
        try {
            let endpoint = fixture.pin()
            @Expect(fixture.host.unmount(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))).isOk(), true)
            @Expect(fixture.host.mount(fixture.record).isOk(), true)
            @Expect(pinnedCode(fixture.call(endpoint, "target-thread", "old")), "plugin.service_endpoint_stale")
            @Expect(selectionCode(fixture.host.pinServiceEndpoint(fixture.grant, fixture.context("target-thread", "old-grant"),
                ThreadId("maintenance-thread"), "session", fixture.host.instanceGeneration(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))))),
                "plugin.service_binding_invalid")
            @Expect(fixture.host.closeServiceEndpoint(endpoint, timeoutMillis: 2000).isOk(), true)
        } finally { fixture.close() }
    }

    @TestCase
    func cancelAndBusyChecksDoNotWaitForObserverOrReportEarlyReclamation(): Unit {
        let fixture = PinnedServiceFixture()
        let observer = PinnedServiceBlockingObserver()
        var pending: ?Future<Result<ProductJavaScriptPluginInvocationResult>> = None
        try {
            let endpoint = fixture.pin()
            let context = fixture.context("target-thread", "held")
            pending = Some(spawn { fixture.host.invokeService(endpoint, "{\"mode\":\"service_read\"}",
                fixture.identity(context, "held"), context, observer: Some(observer)) })
            let deadline = MonoTime.now() + Duration.second * 5
            while (!observer.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(observer.entered.load(), true)
            @Expect(pinnedCode(fixture.call(endpoint, "target-thread", "second")), "plugin.service_endpoint_busy")
            let started = MonoTime.now()
            @Expect(fixture.cancellation.cancel(), true)
            @Expect((MonoTime.now() - started).toMilliseconds() < 500, true)
            let closed = fixture.host.closeServiceEndpoint(endpoint, timeoutMillis: 100)
            @Expect(["extension.cleanup_pending", "plugin.service_cleanup_pending"].contains(pinnedCode(closed)), true)
            observer.release.store(true)
            @Expect(pinnedCode(pending.getOrThrow().get()), "extension.cancelled")
            @Expect(fixture.host.closeServiceEndpoint(endpoint, timeoutMillis: 2000).isOk(), true)
        } finally {
            observer.release.store(true)
            fixture.cancellation.cancel()
            try { match (pending) { case Some(value) => let _ = value.get(); case None => () } }
            finally { fixture.close() }
        }
    }
}
