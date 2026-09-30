package extension_runtime_contract

import agent_sdk.*
import agent_extension_runtime.*
import yjson.*
import yjson_support.*
import sdk_fixture_extension.*
import std.collection.*
import workspace_search_extension.*
import workspace_write_extension.*
import ast_extension.*
import web_search_extension.*

  import process4cj.*
  import std.fs.*
  import std.sync.*
main(): Int64 {
    versionContracts()
    manifestContracts()
    pluginPackageContracts()
    runtimeContracts()
    safeLifecycleContracts()
    migratedFirstPartyContracts()
    fixtureContract()
  javascriptHostContracts()
    piJavascriptApiContracts()
    piNoUiDependencyContracts()
    piSupportedEventContracts()
    piUnsupportedApiContracts()
    println("extension manifest/runtime contract passed")
    0
}

func safeLifecycleContracts(): Unit {
    let host = RecordingGenerationHost()
    let runtime = SafeExtensionLifecycleRuntime(host)
    expect(runtime.mountInitial(searchProvider(), generation: 12u64).isOk(),
        "generation lifecycle mounts an initial compiled provider")
    let oldLease = mustLease(runtime.acquire("axyndra.workspace-search"))
    expect(oldLease.generation == 12u64, "invocation lease freezes the admitted generation")
    expect(runtime.reload(searchProvider(), 13u64).isOk(),
        "reload mounts the new generation before draining the old generation")
    expect(host.events.toArray() == [
        "mount:12", "activate:12", "mount:13", "activate:13", "stop:12"
    ], "generation switch order is mount, activate, then stop-old-admission")
    let newLease = mustLease(runtime.acquire("axyndra.workspace-search"))
    expect(newLease.generation == 13u64, "new invocations use only the newest generation")
    let draining = runtime.diagnostics()
    expect(draining[0].state == ExtensionLifecycleState.Draining &&
        draining[0].inFlight == 1u64 && !draining[0].accepting,
        "old generation stops admission while its pinned invocation drains")
    oldLease.release()
    oldLease.release()
    expect(runtime.diagnostics()[0].state == ExtensionLifecycleState.Inactive &&
        host.events.contains("dispose:12"),
        "last idempotent lease release disposes the drained generation exactly once")
    newLease.release()

    let quarantineHost = RecordingGenerationHost()
    let quarantine = SafeExtensionLifecycleRuntime(quarantineHost)
    expect(quarantine.mountInitial(writeProvider(), generation: 20u64).isOk(), "quarantine fixture mounts")
    let stuck = mustLease(quarantine.acquire("axyndra.workspace-write"))
    expect(quarantine.reload(writeProvider(), 21u64).isOk(), "quarantine fixture begins drain")
    expect(!quarantine.finishDrain("axyndra.workspace-write", 20u64).isOk() &&
        quarantine.diagnostics()[0].state == ExtensionLifecycleState.Quarantined &&
        !quarantineHost.events.contains("dispose:20"),
        "drain deadline quarantines rather than force-unloading in-flight code")
    stuck.release()
    expect(quarantine.diagnostics()[0].state == ExtensionLifecycleState.Quarantined,
        "quarantine requires explicit recovery after the stuck lease settles")

    let signed = SignedExtensionPackageManifest(
        "third-party.safe", "1.0.0", ">=1.1.0 <1.2.0", "1",
        "module.wasm", ["tool:inspect"], ["filesystem"], ["workspace.read"],
        1u32, "same-major", "sha256:abc", "ed25519:signature"
    )
    let verified = validateIsolatedPluginPackage(
        signed, ExtensionExecutionKind.WasmComponent, 1u64,
        ["workspace.read"], FixedSignatureVerifier(true)
    )
    expect(match (verified) {
        case SafeLifecycleResult.Ok(request) =>
            !request.ambientAuthority && request.grantedCapabilities == ["workspace.read"]
        case _ => false
    }, "signed WASM package receives only explicitly granted capabilities")
    expect(!validateIsolatedPluginPackage(
        signed, ExtensionExecutionKind.ProcessPlugin, 1u64,
        [], FixedSignatureVerifier(true)
    ).isOk(), "plugin capability requests cannot exceed the profile ceiling")
    expect(!validateIsolatedPluginPackage(
        signed, ExtensionExecutionKind.ProcessPlugin, 1u64,
        ["workspace.read"], FixedSignatureVerifier(false)
    ).isOk(), "invalid package signatures fail closed")
    expect(!validateIsolatedPluginPackage(
        signed, ExtensionExecutionKind.TrustedNative, 1u64,
        ["workspace.read"], FixedSignatureVerifier(true)
    ).isOk(), "third-party package validator cannot load native code in-process")

    let cycleHost = RecordingGenerationHost()
    let cycles = SafeExtensionLifecycleRuntime(cycleHost)
    expect(cycles.mountInitial(searchProvider()).isOk(), "lifecycle stress fixture mounts")
    for (generation in 2u64..1002u64) {
        expect(cycles.reload(searchProvider(), generation).isOk(), "generation reload stress cycle succeeds")
    }
    var inactive: Int64 = 0
    var active: Int64 = 0
    for (diagnostic in cycles.diagnostics()) {
        if (diagnostic.state == ExtensionLifecycleState.Inactive) { inactive += 1 }
        if (diagnostic.state == ExtensionLifecycleState.Active) { active += 1 }
    }
    expect(inactive == 1000 && active == 1,
        "1000 reload cycles leave one active generation and no mounted old generation")

    let rollbackHost = RecordingGenerationHost()
    rollbackHost.failStopGeneration = 30u64
    let rollback = SafeExtensionLifecycleRuntime(rollbackHost)
    expect(rollback.mountInitial(searchProvider(), generation: 30u64).isOk(), "reload rollback fixture mounts")
    expect(!rollback.reload(searchProvider(), 31u64).isOk(), "failure to stop old admission rejects reload")
    let rollbackDiagnostics = rollback.diagnostics()
    expect(rollbackDiagnostics[0].state == ExtensionLifecycleState.Active &&
        rollbackDiagnostics[0].accepting &&
        rollbackDiagnostics[1].state == ExtensionLifecycleState.Inactive,
        "failed generation switch disposes the new generation and retains the old active generation")

    let activationHost = RecordingGenerationHost()
    activationHost.failActivateGeneration = 41u64
    let activation = SafeExtensionLifecycleRuntime(activationHost)
    expect(!activation.mountInitial(searchProvider(), generation: 41u64).isOk(),
        "activation failure rejects the initial generation")
    expect(activationHost.events.toArray() == ["mount:41", "activate:41", "stop:41", "dispose:41"] &&
        activation.diagnostics()[0].state == ExtensionLifecycleState.Failed &&
        !activation.acquire("axyndra.workspace-search").isOk(),
        "activation failure cleans mounted resources without admitting invocations")
    expect(activation.mountInitial(searchProvider(), generation: 42u64).isOk(),
        "a cleaned activation failure permits a fresh generation")
    activationHost.failActivateGeneration = 43u64
    activationHost.failDisposeGeneration = 43u64
    expect(match (activation.reload(searchProvider(), 43u64)) {
        case SafeLifecycleResult.Err(error) => error.contains("activate.failed") && error.contains("dispose.failed")
        case _ => false
    }, "failed activation reports both original and cleanup errors")
    let failedGeneration = activation.diagnostics()[2]
    expect(failedGeneration.state == ExtensionLifecycleState.Quarantined &&
        !failedGeneration.accepting && failedGeneration.error.contains("dispose.failed"),
        "incomplete cleanup remains quarantined with diagnostic evidence")
    let retained = mustLease(activation.acquire("axyndra.workspace-search"))
    expect(retained.generation == 42u64, "failed reload preserves the old active generation")
    retained.release()
    let stopFailureHost = RecordingGenerationHost()
    stopFailureHost.failActivateGeneration = 50u64
    stopFailureHost.failStopGeneration = 50u64
    let stopFailure = SafeExtensionLifecycleRuntime(stopFailureHost)
    expect(!stopFailure.mountInitial(searchProvider(), generation: 50u64).isOk() &&
        stopFailureHost.events.toArray() == ["mount:50", "activate:50", "stop:50", "dispose:50"] &&
        stopFailure.diagnostics()[0].state == ExtensionLifecycleState.Quarantined &&
        stopFailure.diagnostics()[0].error.contains("stop.failed"),
        "stop failure still attempts disposal and preserves incomplete cleanup diagnostics")
    let throwCleanupHost = RecordingGenerationHost()
    throwCleanupHost.failActivateGeneration = 51u64
    throwCleanupHost.throwDisposeGeneration = 51u64
    let throwCleanup = SafeExtensionLifecycleRuntime(throwCleanupHost)
    expect(!throwCleanup.mountInitial(searchProvider(), generation: 51u64).isOk() &&
        throwCleanup.diagnostics()[0].state == ExtensionLifecycleState.Quarantined &&
        throwCleanup.diagnostics()[0].error.contains("host.lifecycle_exception"),
        "a throwing activation cleanup remains observable and incomplete")
}

func mustLease(result: SafeLifecycleResult<ExtensionInvocationLease>): ExtensionInvocationLease {
    match (result) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
}

class FixedSignatureVerifier <: ExtensionPackageSignatureVerifier {
    private let valid: Bool
    init(valid: Bool) { this.valid = valid }
    public func verify(_manifest: SignedExtensionPackageManifest): Bool {
        let _ = _manifest
        valid
    }
}

class RecordingGenerationHost <: GenerationLifecycleHost {
    let events = ArrayList<String>()
    var failStopGeneration: UInt64 = 0u64
    var failActivateGeneration: UInt64 = 0u64
    var failDisposeGeneration: UInt64 = 0u64
    var throwDisposeGeneration: UInt64 = 0u64
    public func mount(_provider: CompiledExtensionProvider, generation: UInt64): HostLifecycleResult {
        let _ = _provider
        events.add("mount:${generation}")
        HostLifecycleResult.Ok
    }
    public func activate(_extensionId: String, generation: UInt64): HostLifecycleResult {
        let _ = _extensionId
        events.add("activate:${generation}")
        if (generation == failActivateGeneration) {
            return HostLifecycleResult.Err("activate.failed", "injected activation failure")
        }
        HostLifecycleResult.Ok
    }
    public func stopAdmitting(_extensionId: String, generation: UInt64): HostLifecycleResult {
        let _ = _extensionId
        events.add("stop:${generation}")
        if (generation == failStopGeneration) {
            HostLifecycleResult.Err("stop.failed", "injected stop-admission failure")
        } else {
            HostLifecycleResult.Ok
        }
    }
    public func dispose(_extensionId: String, generation: UInt64): HostLifecycleResult {
        let _ = _extensionId
        events.add("dispose:${generation}")
        if (generation == throwDisposeGeneration) { throw IllegalStateException("injected cleanup exception") }
        if (generation == failDisposeGeneration) {
            return HostLifecycleResult.Err("dispose.failed", "injected disposal failure")
        }
        HostLifecycleResult.Ok
    }
}

func versionContracts(): Unit {
    let v100 = SemanticVersion(1, 0, 0)
    let v101 = SemanticVersion(1, 0, 1)
    let v110 = SemanticVersion(1, 1, 0)
    let v200 = SemanticVersion(2, 0, 0)
    expect(v100.lessThan(v101) && v101.lessThan(v110) && v110.lessThan(v200),
        "semantic versions compare patch, minor, then major")
    let range = SdkCompatibility(v100, v200)
    expect(range.includes(v100) && range.includes(v110) && !range.includes(v200),
        "SDK range is min-inclusive and max-exclusive")
}

func migratedFirstPartyContracts(): Unit {
    let astManifest = mustManifest(astExtensionManifest())
    let webManifest = mustManifest(webSearchExtensionManifest())
    expect(astManifest.tools == ["ast_grep", "ast_edit"] &&
        astManifest.capabilities == ["workspace.read", "workspace.write"] &&
        astManifest.requirements.executables == ["ast-grep"] &&
        astManifest.sdk.minimum == SemanticVersion(2, 0, 0) &&
        astManifest.sdk.maximumExclusive == SemanticVersion(3, 0, 0),
        "AST manifest declares static tools, authority requirements, and executable")
    expect(webManifest.tools == ["web_search"] && webManifest.capabilities == ["network.http"] &&
        webManifest.requirements.executables == ["curl"] &&
        webManifest.sdk.minimum == SemanticVersion(2, 0, 0) &&
        webManifest.sdk.maximumExclusive == SemanticVersion(3, 0, 0),
        "web manifest declares network without granting it")

    let probe = FakeProbe()
    probe.available.add("ast-grep")
    probe.available.add("curl")
    let host = RecordingLifecycleHost()
    let runtime = ExtensionRuntime(host, probe: probe)
    expect(runtime.start(
        [webProvider(), astProvider()],
        [ConfiguredExtension("axyndra.web-search"), ConfiguredExtension("axyndra.ast")]
    ).isOk(), "migrated first-party extensions activate through the canonical runtime")
    expect(host.activationOrder.toArray() == ["axyndra.ast", "axyndra.web-search"],
        "migrated first-party activation order is deterministic")
    expect(host.activeTools.contains("ast_grep") && host.activeTools.contains("ast_edit") &&
        host.activeTools.contains("web_search"), "migrated tools are registered by lifecycle host")

    let unavailable = ExtensionRuntime(RecordingLifecycleHost(), probe: FakeProbe())
    expect(unavailable.start(
        [astProvider(), webProvider()],
        [ConfiguredExtension("axyndra.ast"), ConfiguredExtension("axyndra.web-search")]
    ).isOk(), "missing requirements on optional extensions do not fail product startup")
    expect(unavailable.diagnostics()[0].state == ExtensionLifecycleState.Failed &&
        unavailable.diagnostics()[1].state == ExtensionLifecycleState.Failed,
        "optional requirement failures remain explicit diagnostics")
}

func manifestContracts(): Unit {
    let valid = workspaceSearchExtensionManifest()
    let parsed = mustManifest(valid)
    expect(parsed.schemaVersion == 1 && parsed.id == "axyndra.workspace-search", "valid manifest parses")
    expect(parsed.sdk.includes(SemanticVersion(2, 0, 0)), "current SDK is compatible")
    expect(parseExtensionManifest(valid.replace(
        "\"requirements\":", "\"futureOptional\": true, \"requirements\":"
    )).isOk(), "unknown optional top-level fields are tolerated")

    expectManifestKind(valid.replace("\"schemaVersion\": 1", "\"schemaVersion\": 0"),
        ExtensionRuntimeErrorKind.ManifestSchemaUnsupported, "unsupported old schema is rejected")
    expectManifestKind(valid.replace("\"schemaVersion\": 1", "\"schemaVersion\": 2"),
        ExtensionRuntimeErrorKind.ManifestSchemaUnsupported, "future schema is rejected")

    expectManifestFailure(valid.replace("\"id\": \"axyndra.workspace-search\",", ""), "missing id")
    expectManifestFailure(valid.replace("axyndra.workspace-search", "Invalid Id"), "invalid id")
    expectManifestFailure(valid.replace("\"version\": \"1.0.0\",", ""), "missing version")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"1.x\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "non-numeric extension version is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"1\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "one-component version is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"1.2\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "two-component version is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"1.2.3.4\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "four-component version is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"-1.0.0\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "negative version is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"01.0.0\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "non-canonical leading zero is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \" 1.0.0\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "ambiguous version whitespace is rejected")
    expectManifestKind(valid.replace("\"version\": \"1.0.0\"", "\"version\": \"9223372036854775808.0.0\""),
        ExtensionRuntimeErrorKind.ExtensionVersionMalformed, "overflowing version is rejected")
    expectManifestKind(valid.replace("\"min\": \"2.0.0\"", "\"min\": \"3.0.0\""),
        ExtensionRuntimeErrorKind.SdkRangeMalformed, "empty SDK range is rejected")
    expectManifestFailure(valid.replace("\"tools\": [\"grep\"]", "\"tools\": [\"grep\", \"grep\"]"), "duplicate tool declaration")
    expectManifestFailure(valid.replace("\"capabilities\": [\"workspace.read\"]", "\"capabilities\": [\"workspace.read\", \"workspace.read\"]"), "duplicate capability declaration")
    expectManifestFailure("{", "malformed JSON")
}
// Pi package examples follow packages.md at
// earendil-works/pi fd3b009d9f8d4a815de697ae75ce787ba76e9b13.
// Codex portable fixtures follow the published plugin schema and layout.
func pluginPackageContracts(): Unit {
    let declared = inspectedPluginPackage("fixtures/pi-manifest")
    expect(declared.ecosystem == PluginEcosystem.Pi &&
        declared.namespace == "pi:my-package" &&
        declared.manifestPath == "package.json" &&
        declared.compatibilityProfile == "pi-package-declared-v1",
        "declared Pi packages receive a stable namespace and profile")
    expect(declared.components.size == 4 &&
        declared.components[0].relativePath == "skills" &&
        declared.components[0].identity == "pi:my-package/skill/skills" &&
        declared.components[0].status == PluginComponentStatus.Supported &&
        declared.requestedCapabilities.isEmpty(),
        "Pi resources have normalized identities and declarations grant no capabilities")
    let declaredAgain = inspectedPluginPackage("fixtures/pi-manifest")
    expect(declared.components[0].identity == declaredAgain.components[0].identity &&
        declared.contentDigest == declaredAgain.contentDigest &&
        declared.contentDigest.startsWith("sha256:") && declared.contentDigest.size == 71,
        "package and component identities and content digests are deterministic")

    let conventional = inspectedPluginPackage("fixtures/pi-conventional")
    expect(conventional.compatibilityProfile == "pi-package-conventions-v1" &&
        conventional.components.size == 4 &&
        !hasPackageComponent(conventional, PluginComponentKind.Hook, "hooks/ignored.json") &&
        !hasPackageComponent(conventional, PluginComponentKind.Command, "commands/ignored.md"),
        "Pi convention loading is limited to extensions skills prompts and themes")
    let emptyDeclaration = inspectedPluginPackage("fixtures/pi-empty-declaration")
    expect(emptyDeclaration.components.isEmpty(),
        "an explicit empty Pi resource list suppresses convention discovery")

    let dependencies = inspectedPluginPackage("fixtures/pi-dependencies")
    expect(dependencies.dependencies.size == 3 &&
        dependencies.dependencies[0].name == "missing-runtime" &&
        dependencies.dependencies[0].versionRange == "^1.2.0" &&
        !dependencies.dependencies[0].optional &&
        dependencies.dependencies[1].optional &&
        dependencies.dependencies[2].development &&
        dependencies.missingDependencies == ["missing-runtime"] &&
        dependencies.components[0].relativePath == "extensions/index.js" &&
        dependencies.components[0].identity == "pi:dependency-package/extension/extensions/index.js",
        "Pi dependency metadata reports missing runtime dependencies and normalizes ./ paths")
    let contentA = inspectedPluginPackage("fixtures/pi-content-a")
    let contentB = inspectedPluginPackage("fixtures/pi-content-b")
    expect(contentA.contentDigest != contentB.contentDigest,
        "package-tree digest changes when a component file changes")

    let portable = inspectedPluginPackage("fixtures/codex-portable")
    expect(portable.ecosystem == PluginEcosystem.Codex &&
        portable.manifestPath == "plugin.json" &&
        portable.compatibilityProfile == "codex-portable-v1" &&
        portable.overlayPath == "plugin.json#extensions.com.openai" &&
        hasPackageComponent(portable, PluginComponentKind.Skill, "skills") &&
        hasPackageComponent(portable, PluginComponentKind.Mcp, "mcp.json") &&
        hasPackageComponent(portable, PluginComponentKind.HostedOnly, ".app.json", status: PluginComponentStatus.Blocked) &&
        !hasPackageKind(portable, PluginComponentKind.Hook) &&
        portable.requestedCapabilities.isEmpty(),
        "portable Codex package uses root skills and MCP with a non-merging OpenAI overlay")
    let fallback = inspectedPluginPackage("fixtures/codex-fallback")
    expect(fallback.manifestPath == "plugin.json" &&
        fallback.overlayPath == ".codex-plugin/plugin.json" &&
        hasPackageComponent(fallback, PluginComponentKind.Hook, "hooks/hooks.json", status: PluginComponentStatus.Blocked) &&
        !hasPackageKind(fallback, PluginComponentKind.Skill) &&
        !hasPackageKind(fallback, PluginComponentKind.Mcp),
        "Codex fallback is selected only when the portable overlay is absent")
    expect(match (inspectPluginPackage("fixtures/codex-invalid-schema")) {
        case PluginPackageResult.Err(error) => error.code == "plugin.schema_unsupported"
        case PluginPackageResult.Ok(_) => false
    }, "unsupported Codex schema is rejected instead of guessed")
    expect(match (inspectPluginPackage("fixtures/codex-invalid-mcp")) {
        case PluginPackageResult.Err(error) => error.code == "plugin.schema_unsupported"
        case PluginPackageResult.Ok(_) => false
    }, "portable Codex MCP schema is validated before discovery")
    expect(match (inspectPluginPackage("fixtures/codex-invalid-mcp-config")) {
        case PluginPackageResult.Err(error) => error.code == "plugin.codex_mcp_servers_required"
        case PluginPackageResult.Ok(_) => false
    }, "portable Codex MCP requires an object-valued mcpServers map")
}

func inspectedPluginPackage(root: String): PluginPackageDescriptor {
    match (inspectPluginPackage(root)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) =>
            throw IllegalStateException(error.code + ": " + error.message)
    }
}

func hasPackageComponent(
    descriptor: PluginPackageDescriptor,
    kind: PluginComponentKind,
    path: String,
    status!: PluginComponentStatus = PluginComponentStatus.Supported
): Bool {
    for (component in descriptor.components) {
        if (component.kind == kind && component.relativePath == path &&
            component.status == status) {
            return true
        }
    }
    false
}

func hasPackageKind(descriptor: PluginPackageDescriptor, kind: PluginComponentKind): Bool {
    for (component in descriptor.components) {
        if (component.kind == kind) { return true }
    }
    false
}


func runtimeContracts(): Unit {
    let probe = FakeProbe()
    probe.available.add("rg")
    let host = RecordingLifecycleHost()
    let runtime = ExtensionRuntime(host, probe: probe)
    expect(runtime.start(
        [writeProvider(), searchProvider()],
        [
            ConfiguredExtension("axyndra.workspace-write", required: true),
            ConfiguredExtension("axyndra.workspace-search", required: true)
        ]
    ).isOk(), "built-in extensions activate")
    expect(host.activationOrder.toArray() == ["axyndra.workspace-search", "axyndra.workspace-write"], "registration order is lexical and deterministic")
    let diagnostics = runtime.diagnostics()
    expect(diagnostics.size == 2 && diagnostics[0].state == ExtensionLifecycleState.Active, "active diagnostics are deterministic")
    expect(diagnostics[0].tools == ["grep"] && diagnostics[0].capabilities == ["workspace.read"] && diagnostics[0].requirements == ["rg"], "diagnostics project declarations")
    expect(runtime.deactivate("axyndra.workspace-search").isOk(), "deactivation succeeds")
    expect(runtime.deactivate("axyndra.workspace-search").isOk(), "double deactivation is idempotent")
    expect(!host.activeTools.contains("grep"), "inactive extension tool is unavailable")
    expect(runtime.activate("axyndra.workspace-search").isOk(), "inactive extension reactivates")
    host.failDeactivationId = "axyndra.workspace-search"
    expect(!runtime.shutdown().isOk() && host.deactivationOrder.toArray() ==
        ["axyndra.workspace-search", "axyndra.workspace-search", "axyndra.workspace-write"],
        "shutdown continues cleaning other extensions after a failure")
    expect(host.activeTools.toArray() == ["grep"] && runtime.diagnostics()[0].error.isSome(),
        "failed shutdown retains only unfinished work and its error")
    expect(!runtime.shutdown().isOk() && host.deactivationOrder.size == 4,
        "repeated shutdown retries unfinished work and does not report false success")
    expect(!runtime.activate("axyndra.workspace-write").isOk(),
        "shutdown closes activation admission even when cleanup is incomplete")
    host.failDeactivationId = ""
    expect(runtime.shutdown().isOk() && host.activeTools.isEmpty(), "shutdown retry finishes cleanup")
    expect(runtime.shutdown().isOk() && host.deactivationOrder.size == 5,
        "completed shutdown does not deactivate a second time")
    let stoppedBeforeStart = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(stoppedBeforeStart.shutdown().isOk() &&
        !stoppedBeforeStart.start([writeProvider()], [ConfiguredExtension("axyndra.workspace-write")]).isOk(),
        "shutdown also closes startup admission")
    let throwingHost = RecordingLifecycleHost()
    let throwingRuntime = ExtensionRuntime(throwingHost, probe: probe)
    expect(throwingRuntime.start([searchProvider(), writeProvider()], [
        ConfiguredExtension("axyndra.workspace-search"), ConfiguredExtension("axyndra.workspace-write")
    ]).isOk(), "throwing shutdown fixture starts")
    throwingHost.throwDeactivationId = "axyndra.workspace-search"
    expect(!throwingRuntime.shutdown().isOk() && throwingHost.activeTools.toArray() == ["grep"] &&
        throwingRuntime.diagnostics()[0].error.isSome(),
        "a throwing host is diagnosed without skipping other shutdown work")
    throwingHost.throwDeactivationId = ""
    expect(throwingRuntime.shutdown().isOk(), "throwing shutdown work remains retryable")

    let duplicate = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(match (duplicate.start(
        [searchProvider(), searchProvider()],
        [ConfiguredExtension("axyndra.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.DuplicateExtensionId
        case _ => false
    }, "duplicate compiled IDs fail closed")

    let missingProbe = FakeProbe()
    let missing = ExtensionRuntime(RecordingLifecycleHost(), probe: missingProbe)
    expect(match (missing.start(
        [searchProvider()],
        [ConfiguredExtension("axyndra.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.RequirementMissing
        case _ => false
    }, "missing required executable fails required startup")

    let unavailableProbe = FakeProbe()
    unavailableProbe.unavailable.add("rg")
    let unavailable = ExtensionRuntime(RecordingLifecycleHost(), probe: unavailableProbe)
    expect(match (unavailable.start(
        [searchProvider()],
        [ConfiguredExtension("axyndra.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.RequirementUnavailable
        case _ => false
    }, "present but non-executable requirement is unavailable")

    let optional = ExtensionRuntime(RecordingLifecycleHost(), probe: missingProbe)
    expect(optional.start(
        [searchProvider(), writeProvider()],
        [
            ConfiguredExtension("axyndra.workspace-search"),
            ConfiguredExtension("axyndra.workspace-write", enabled: false)
        ]
    ).isOk(), "optional failure and disabled extension do not fail startup")
    expect(optional.diagnostics()[0].state == ExtensionLifecycleState.Failed && optional.diagnostics()[1].state == ExtensionLifecycleState.Inactive, "optional failure and disabled reasons remain diagnostic")

    let futureManifest = workspaceWriteExtensionManifest().replace(
        "\"min\": \"2.0.0\"", "\"min\": \"3.0.0\""
    ).replace("\"maxExclusive\": \"3.0.0\"", "\"maxExclusive\": \"4.0.0\"")
    let incompatible = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(match (incompatible.start(
        [CompiledExtensionProvider("axyndra.workspace-write", "future", futureManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("axyndra.workspace-write", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) =>
            error.kind == ExtensionRuntimeErrorKind.SdkTooOld &&
            error.phase == ExtensionRuntimePhase.Compatibility &&
            error.extensionId == "axyndra.workspace-write" &&
            error.extensionVersion == "1.0.0" &&
            error.sdkMinimum == "3.0.0" && error.sdkMaximumExclusive == "4.0.0" &&
            error.hostSdkVersion == AGENT_SDK_VERSION
        case _ => false
    }, "future SDK range is rejected before activation with structured context")
    let exactMaxManifest = workspaceWriteExtensionManifest().replace(
        "\"min\": \"2.0.0\"", "\"min\": \"1.0.0\""
    ).replace("\"maxExclusive\": \"3.0.0\"", "\"maxExclusive\": \"2.0.0\"")
    let exactMax = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(match (exactMax.start(
        [CompiledExtensionProvider("axyndra.workspace-write", "old-range", exactMaxManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("axyndra.workspace-write", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.SdkTooNew
        case _ => false
    }, "host at maxExclusive is rejected")

    let optionalIncompatibleHost = RecordingLifecycleHost()
    let optionalIncompatible = ExtensionRuntime(optionalIncompatibleHost, probe: probe)
    expect(optionalIncompatible.start(
        [CompiledExtensionProvider("axyndra.workspace-write", "future-optional", futureManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("axyndra.workspace-write")]
    ).isOk(), "optional incompatible extension does not abort startup")
    expect(optionalIncompatibleHost.activeTools.isEmpty() &&
        optionalIncompatible.diagnostics()[0].state == ExtensionLifecycleState.Failed &&
        !optionalIncompatible.diagnostics()[0].compatible,
        "optional incompatibility exposes diagnostics and zero tools")
    expect(!optionalIncompatible.activate("axyndra.workspace-write").isOk() &&
        optionalIncompatibleHost.activeTools.isEmpty() &&
        optionalIncompatible.diagnostics()[0].state == ExtensionLifecycleState.Failed,
        "manual activation cannot bypass an optional extension SDK incompatibility")

    let mismatch = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    let drift = workspaceWriteExtensionManifest().replace("\"version\": \"1.0.0\"", "\"version\": \"1.0.1\"")
    expect(match (mismatch.start(
        [CompiledExtensionProvider("axyndra.workspace-write", "drift", drift, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("axyndra.workspace-write", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.MetadataMismatch
        case _ => false
    }, "manifest/code metadata drift is rejected")

    let atomicHost = RecordingLifecycleHost()
    atomicHost.activeTools.add("occupied")
    let atomicRuntime = ExtensionRuntime(atomicHost, probe: probe)
    let multi = StaticExtension("third-party.atomic", "Atomic", "1.0.0", "Atomic extension.", [StubTool("fresh"), StubTool("occupied")])
    let atomicManifest = manifest("third-party.atomic", "Atomic", "Atomic extension.", ["fresh", "occupied"])
    expect(match (atomicRuntime.start(
        [CompiledExtensionProvider("third-party.atomic", "atomic", atomicManifest, { => multi })],
        [ConfiguredExtension("third-party.atomic", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.DuplicateTool
        case _ => false
    }, "duplicate tool rejects activation")
    expect(!atomicHost.activeTools.contains("fresh") && atomicHost.activeTools.contains("occupied"), "failed activation leaves no partial tools")
}

class JavaScriptProgressRecorder <: JavaScriptHostObserver {
    let count = AtomicInt64(0)
    let messages = ArrayList<String>()

    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        let _ = invocationId
        count.fetchAdd(1)
        messages.add(progressJson)
        JavaScriptHostResult.Ok(())
    }
}
class JavaScriptServiceRecorder <: JavaScriptHostObserver {
    let progressCountValue = AtomicInt64(0)
    let serviceCountValue = AtomicInt64(0)
    var lastInvocationId = ""
    var lastRequestId = ""
    var lastService = ""
    var lastArgumentsJson = ""

    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        let _ = progressJson
        lastInvocationId = invocationId
        progressCountValue.fetchAdd(1)
        JavaScriptHostResult.Ok(())
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        lastInvocationId = invocationId
        lastRequestId = requestId
        lastService = service
        lastArgumentsJson = argumentsJson
        serviceCountValue.fetchAdd(1)
        JavaScriptHostResult.Ok("{\"source\":\"host\",\"controlled\":true}")
    }
}
// The support fixture bypasses the product sandbox to test protocol behavior independently.
class DirectJavaScriptFixtureLauncher <: JavaScriptHostProcessLauncher {
    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        try {
            JavaScriptHostResult.Ok(startProcess(command))
        } catch (error: Exception) {
            JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.process_spawn_failed", error.message
            ))
        }
    }
}

func startFixtureJavaScriptExtensionHost(
    request: JavaScriptHostLaunchRequest,
    observer!: ?JavaScriptHostObserver = None
): JavaScriptHostResult<JavaScriptExtensionHost> {
    startJavaScriptExtensionHostWithLauncher(
        request, DirectJavaScriptFixtureLauncher(), observer: observer
    )
}

func fixtureInvocationIdentity(suffix: String): JavaScriptHostInvocationIdentity {
    JavaScriptHostInvocationIdentity(
        threadId: "thread-" + suffix,
        runId: "run-" + suffix,
        epoch: 1,
        operationId: "operation-" + suffix,
        callId: "call-" + suffix
    )
}
func javascriptHostContracts(): Unit {
    let root = canonicalize(Path("fixtures")).toString()
    let boundary = repeatedFixtureText("x", 256)
    let identityAtLimit = JavaScriptHostInvocationIdentity(
        threadId: boundary, runId: "run", epoch: 1, operationId: "operation", callId: "call"
    )
    expect(identityAtLimit.threadId.size == 256, "identity fields accept the declared byte limit")
    let identityTooLong = try {
        JavaScriptHostInvocationIdentity(
            threadId: repeatedFixtureText("x", 257), runId: "run", epoch: 1,
            operationId: "operation", callId: "call"
        )
        false
    } catch (_: Exception) { true }
    expect(identityTooLong, "oversized invocation identity is rejected before framing")
    let boundedRequest = JavaScriptHostLaunchRequest(
        root, "pi_echo_v1.js", extensionId: boundary, extensionVersion: boundary
    )
    expect(boundedRequest.extensionId.size == 256 && boundedRequest.extensionVersion.size == 256,
        "extension id and version accept the declared byte limit")
    let requestTooLong = try {
        JavaScriptHostLaunchRequest(
            root, "pi_echo_v1.js", extensionId: repeatedFixtureText("x", 257),
            extensionVersion: "1.0.0"
        )
        false
    } catch (_: Exception) { true }
    expect(requestTooLong, "oversized extension id is rejected before process launch")
    let versionTooLong = try {
        JavaScriptHostLaunchRequest(
            root, "pi_echo_v1.js", extensionId: "pi.version.limit",
            extensionVersion: repeatedFixtureText("v", 257)
        )
        false
    } catch (_: Exception) { true }
    expect(versionTooLong, "oversized extension version is rejected before process launch")
    let versionWithNul = try {
        JavaScriptHostLaunchRequest(
            root, "pi_echo_v1.js", extensionId: "pi.version.nul",
            extensionVersion: "1.0.0\u{0000}"
        )
        false
    } catch (_: Exception) { true }
    expect(versionWithNul, "NUL in extension version is rejected before process launch")
    let observer = JavaScriptProgressRecorder()
    let hostV1 = match (startFixtureJavaScriptExtensionHost(
        JavaScriptHostLaunchRequest(
            root,
            "pi_echo_v1.js",
            extensionId: "pi.fixed.v1",
            extensionVersion: "1.0.0",
            generation: 41u64,
            grantedCapabilities: ["workspace.read"]
        ),
        observer: Some(observer)
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(hostV1.generation == 41u64 && hostV1.tools.size == 3,
        "Node JavaScript extension registers the fixed tool set")
    expect(hostV1.tools[0].inputSchemaJson.contains("object"),
        "Node JavaScript extension exposes its input schema")
    let deepArguments = "{\"value\":" + repeatedFixtureText("[", 40) +
        "0" + repeatedFixtureText("]", 40) + "}"
    let tooDeep = hostV1.invoke(
        "echo", deepArguments, identity: fixtureInvocationIdentity("too-deep")
    )
    expect(match (tooDeep) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.arguments_invalid"
        case _ => false
    }, "nested invocation JSON is rejected above the configured depth")
    let echoV1 = match (hostV1.invoke("echo", "{\"value\":\"first\"}", identity: fixtureInvocationIdentity("echo-v1"))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!echoV1.isError && echoV1.resultJson.contains("pi-fixed-v1") &&
        echoV1.resultJson.contains("first") && observer.count.load() == 1,
        "fixed-version JavaScript extension returns a result and progress event")
    let probeV1 = match (hostV1.invoke("probe", "{}", identity: fixtureInvocationIdentity("probe-v1"))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(probeV1.resultJson.contains("\"filesystemDenied\":true") &&
        probeV1.resultJson.contains("\"processDenied\":true") &&
        probeV1.resultJson.contains("\"networkDenied\":true"),
        "Node permission policy denies filesystem escape, child processes, and network sockets")
    let environmentHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_environment.js", extensionId: "pi.environment", extensionVersion: "1.0.0", generation: 41u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let environmentResult = match (environmentHost.invoke("environment", "{}", identity: fixtureInvocationIdentity("environment"))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(environmentResult.resultJson.contains("\"home\":\"" + root + "\"") &&
        environmentResult.resultJson.contains("\"tmpdir\":\"" + root + "\"") &&
        environmentResult.resultJson.contains("\"path\":\"/usr/local/bin:/usr/bin:/bin\""),
        "Node extension receives only the sealed host environment")
    environmentHost.close()
    hostV1.close()
    let serviceObserver = JavaScriptServiceRecorder()
    let serviceHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_service_v2.js", extensionId: "pi.service.v2", extensionVersion: "1.0.0"
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let serviceIdentity = fixtureInvocationIdentity("service-broker")
    let serviceResult = match (serviceHost.invoke(
        "service", "{}", identity: serviceIdentity, observer: Some(serviceObserver)
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(serviceResult.resultJson.contains("controlled") &&
        serviceObserver.serviceCountValue.load() == 1 &&
        serviceObserver.lastInvocationId != "" &&
        serviceObserver.lastRequestId == "service-1" &&
        serviceObserver.lastService == "exec" &&
        serviceObserver.lastArgumentsJson.contains("printf controlled") &&
        serviceObserver.progressCountValue.load() == 1,
        "service IPC is bounded, correlated, and returns the host response to the active tool")
    let serviceFlood = serviceHost.invoke(
        "service", "{\"mode\":\"flood\"}",
        identity: fixtureInvocationIdentity("service-flood"), observer: Some(serviceObserver)
    )
    expect((match (serviceFlood) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.protocol_service_limit"
        case _ => false
    }) && serviceHost.isClosed,
        "service request floods close the host before exceeding the per-call limit")
    serviceHost.close()
    let unsupportedServiceHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_service_v2.js", extensionId: "pi.service.unsupported", extensionVersion: "1.0.0"
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let unsupportedService = match (unsupportedServiceHost.invoke(
        "service", "{}", identity: fixtureInvocationIdentity("service-unsupported")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(unsupportedService.resultJson.contains("extension.service_unsupported"),
        "unconfigured service requests receive an explicit unsupported result")
    unsupportedServiceHost.close()
    let cjsHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_commonjs_v1.cjs", extensionId: "axyndra.host.cjs",
        extensionVersion: "1.0.0", generation: 53u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(cjsHost.tools.size == 1, "explicit CommonJS entrypoint completes the host handshake")
    let cjsResult = match (cjsHost.invoke(
        "echo", "{\"value\":\"commonjs\"}", identity: fixtureInvocationIdentity("commonjs")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!cjsResult.isError && cjsResult.resultJson.contains("\"value\":\"commonjs\""),
        "CommonJS fixture returns its observable result")
    cjsHost.close()

    let esmHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_esm_v1.mjs", extensionId: "axyndra.host.esm",
        extensionVersion: "1.0.0", generation: 54u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(esmHost.tools.size == 1, "ES module entrypoint completes the host handshake")
    let esmResult = match (esmHost.invoke(
        "echo", "{\"value\":\"esm\"}", identity: fixtureInvocationIdentity("esm")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!esmResult.isError && esmResult.resultJson.contains("\"value\":\"esm\""),
        "ES module fixture returns its observable result")
    esmHost.close()

    let hostV2 = match (startFixtureJavaScriptExtensionHost(
        JavaScriptHostLaunchRequest(
            root,
            "pi_echo_v2.ts",
            extensionId: "pi.fixed.v2",
            extensionVersion: "1.0.0",
            generation: 42u64
        ),
        observer: Some(observer)
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(hostV2.generation == 42u64 && hostV2.extensionId == "pi.fixed.v2",
        "a second fixed-version TypeScript extension gets an isolated generation")
    let echoV2 = match (hostV2.invoke("echo", "{\"value\":\"second\"}", identity: fixtureInvocationIdentity("echo-v2"))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(echoV2.resultJson.contains("pi-fixed-ts-v2") &&
        echoV2.resultJson.contains("fixed-ts-v2") && echoV2.resultJson.contains("second"),
        "fixed-version TypeScript extension remains independently addressable")

    let cancellation = CancellationSource()
    let cancelFuture = spawn {
        sleep(Duration.millisecond * 100)
        cancellation.cancel()
    }
    let cancelled = hostV2.invoke(
        "delayed",
        "{}",
        identity: fixtureInvocationIdentity("cancel"), cancellation: cancellation.token,
        timeoutMillis: 4000
    )
    let _ = cancelFuture.get()
    expect(match (cancelled) {
        case JavaScriptHostResult.Err(error) => error.code == "process.cancelled"
        case _ => false
    }, "cancelling an in-flight JavaScript invocation terminates the host")
    cancellation.close()
    hostV2.close()

    let unsupported = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_echo_v1.js", runtime: "bun", extensionId: "pi.unsupported", extensionVersion: "1.0.0"
    ))
    expect(match (unsupported) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.runtime_unsupported"
        case _ => false
    }, "unsupported JavaScript runtimes fail with a diagnostic")
    let traversal = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "../pi_echo_v1.js", extensionId: "pi.traversal", extensionVersion: "1.0.0"
    ))
    expect(match (traversal) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.entrypoint_invalid"
        case _ => false
    }, "package-relative entrypoint traversal fails closed")
    expectHandshakeFailure(root, "protocol", 43u64)
    expectHandshakeFailure(root, "extension_id", 43u64)
    expectHandshakeFailure(root, "extension_version", 43u64)
    expectHandshakeFailure(root, "generation", 43u64)
    expectHandshakeFailure(root, "capabilities", 43u64)

    let importedWithoutHostProtocol = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_import_only.mjs", extensionId: "axyndra.host.import-only",
        extensionVersion: "1.0.0", generation: 55u64
    ))
    var importOnlyRejected = false
    match (importedWithoutHostProtocol) {
        case JavaScriptHostResult.Err(error) =>
            importOnlyRejected = error.code == "extension.handshake_invalid"
        case JavaScriptHostResult.Ok(value) => value.close()
    }
    expect(importOnlyRejected,
        "a successfully imported ESM module without the host handshake is not executable compatibility")

    let badProtocolHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_bad_protocol.js", extensionId: "pi.bad-protocol", extensionVersion: "1.0.0", generation: 44u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let badProtocol = badProtocolHost.invoke("echo", "{}", identity: fixtureInvocationIdentity("bad-protocol"))
    let badProtocolCode = match (badProtocol) {
        case JavaScriptHostResult.Err(error) => error.code
        case _ => "unexpected_success"
    }
    let badProtocolClosed = badProtocolHost.isClosed
    expect(badProtocolCode == "extension.protocol_failed" && badProtocolClosed,
        "protocol noise closes the extension host: " + badProtocolCode + ", closed=" + badProtocolClosed.toString())
    for (mode in [
        "wrong_protocol", "wrong_extension_id", "wrong_extension_version", "wrong_generation",
        "wrong_invocation_id", "wrong_tool", "wrong_thread_id", "wrong_run_id", "wrong_epoch",
        "wrong_operation_id", "wrong_call_id"
    ]) {
        expectInvocationProtocolFailure(
            root, mode, "extension.protocol_identity_mismatch"
        )
    }
    expectInvocationProtocolFailure(
        root, "progress_wrong_id", "extension.protocol_identity_mismatch"
    )
    expectInvocationProtocolFailure(
        root, "progress_flood", "extension.protocol_progress_limit"
    )
    expectInvocationProtocolFailure(root, "disconnect", "extension.process_failed")
    expectInvocationProtocolFailure(root, "ignore_cancel", "extension.invocation_timeout")

    let stderrFloodHost = startProtocolFaultHost(root, "stderr_flood", 79u64)
    let stderrFlood = stderrFloodHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("stderr-flood")
    )
    expect(match (stderrFlood) {
        case JavaScriptHostResult.Ok(value) => value.resultJson.contains("stderr_flood") && !stderrFloodHost.isClosed
        case _ => false
    }, "stderr flood is drained independently from protocol stdout")
    stderrFloodHost.close()

    let duplicateReplyHost = startProtocolFaultHost(root, "duplicate_result", 80u64)
    let firstDuplicate = duplicateReplyHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("duplicate-first")
    )
    let staleDuplicate = duplicateReplyHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("duplicate-second")
    )
    expect(match (firstDuplicate) {
        case JavaScriptHostResult.Ok(value) => value.resultJson.contains("duplicate_result")
        case _ => false
    }, "first terminal response is accepted")
    expect(match (staleDuplicate) {
        case JavaScriptHostResult.Err(error) =>
            error.code == "extension.protocol_identity_mismatch" && duplicateReplyHost.isClosed
        case _ => false
    }, "duplicate terminal response cannot contaminate the next invocation")

    let lateServiceRecorder = JavaScriptServiceRecorder()
    let lateServiceHost = startProtocolFaultHost(root, "late_service", 81u64)
    let completedBeforeLateService = lateServiceHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("late-service-first"),
        observer: Some(lateServiceRecorder)
    )
    sleep(Duration.millisecond * 80)
    let rejectedLateService = lateServiceHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("late-service-second"),
        observer: Some(lateServiceRecorder)
    )
    expect(match (completedBeforeLateService) {
        case JavaScriptHostResult.Ok(value) => value.resultJson.contains("late_service")
        case _ => false
    } && match (rejectedLateService) {
        case JavaScriptHostResult.Err(error) =>
            error.code == "extension.protocol_identity_mismatch" && lateServiceHost.isClosed
        case _ => false
    } && lateServiceRecorder.serviceCountValue.load() == 0,
        "a post-completion timer cannot reuse expired invocation authority for a side effect")

    let oversized = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_oversized.js", extensionId: "pi.oversized", extensionVersion: "1.0.0", generation: 45u64, maxFrameBytes: 1024, defaultTimeoutMillis: 1000
    ))
    expect(match (oversized) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.protocol_frame_too_large"
        case _ => false
    }, "oversized protocol frames fail before registration")

    let crashed = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_crash.js", extensionId: "pi.crash", extensionVersion: "1.0.0", generation: 46u64, defaultTimeoutMillis: 1000
    ))
    expect(match (crashed) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.process_failed"
        case _ => false
    }, "a host process crash is surfaced as a launch diagnostic")

    let silentHost = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_silent.js", extensionId: "pi.silent", extensionVersion: "1.0.0", generation: 47u64, defaultTimeoutMillis: 1000
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let activeSilent = spawn {
        silentHost.invoke(
            "silent", "{}", identity: fixtureInvocationIdentity("timeout"), timeoutMillis: 1000
        )
    }
    sleep(Duration.millisecond * 50)
    let busy = silentHost.invoke(
        "silent", "{}", identity: fixtureInvocationIdentity("busy"), timeoutMillis: 1000
    )
    expect(match (busy) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.invocation_busy"
        case _ => false
    }, "single-flight extension host rejects a second unresolved invocation")
    let timed = activeSilent.get()
    expect(match (timed) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.invocation_timeout" && silentHost.isClosed
        case _ => false
    }, "a silent invocation is cancelled at its deadline")
    silentHost.close()

    let duplicate = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_duplicate.js", extensionId: "pi.duplicate", extensionVersion: "1.0.0", generation: 50u64, defaultTimeoutMillis: 1000
    ))
    expect(match (duplicate) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.tool_duplicate"
        case _ => false
    }, "duplicate tool registration fails closed")

    let invalidSchema = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_invalid_schema.mjs", extensionId: "axyndra.host.invalid-schema",
        extensionVersion: "1.0.0", generation: 56u64
    ))
    var invalidSchemaRejected = false
    match (invalidSchema) {
        case JavaScriptHostResult.Err(error) =>
            invalidSchemaRejected = error.code == "extension.tool_schema_invalid"
        case JavaScriptHostResult.Ok(value) => value.close()
    }
    expect(invalidSchemaRejected, "non-object tool schema rejects the staged host directory")

    let malformedSchema = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_invalid_json_schema.mjs", extensionId: "axyndra.host.malformed-schema",
        extensionVersion: "1.0.0", generation: 59u64
    ))
    var malformedSchemaRejected = false
    match (malformedSchema) {
        case JavaScriptHostResult.Err(error) =>
            malformedSchemaRejected = error.code == "extension.tool_schema_invalid"
        case JavaScriptHostResult.Ok(value) => value.close()
    }
    expect(malformedSchemaRejected, "malformed JSON Schema is rejected before host registration")

    let invalidDescription = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "axyndra_host_invalid_description.mjs", extensionId: "axyndra.host.invalid-description",
        extensionVersion: "1.0.0", generation: 57u64
    ))
    var invalidDescriptionRejected = false
    match (invalidDescription) {
        case JavaScriptHostResult.Err(error) =>
            invalidDescriptionRejected = error.code == "extension.tool_description_invalid"
        case JavaScriptHostResult.Ok(value) => value.close()
    }
    expect(invalidDescriptionRejected, "non-text tool description rejects initialization")

    let dynamicRegistrationHost = match (startFixtureJavaScriptExtensionHost(
        JavaScriptHostLaunchRequest(
            root, "axyndra_host_dynamic_registration.mjs", extensionId: "axyndra.host.dynamic",
            extensionVersion: "1.0.0", generation: 58u64
        )
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let dynamicRegistration = dynamicRegistrationHost.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("dynamic-registration")
    )
    var dynamicRegistrationRejected = false
    match (dynamicRegistration) {
        case JavaScriptHostResult.Err(error) =>
            dynamicRegistrationRejected =
                error.code == "extension.tool_registration_unsupported" && dynamicRegistrationHost.isClosed
        case JavaScriptHostResult.Ok(_) => ()
    }
    expect(dynamicRegistrationRejected, "post-ready tool registration during a Run is rejected explicitly")
    dynamicRegistrationHost.close()


    let concurrentV1 = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_echo_v1.js", extensionId: "pi.concurrent.v1", extensionVersion: "1.0.0", generation: 51u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let concurrentV2 = match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_echo_v2.ts", extensionId: "pi.concurrent.v2", extensionVersion: "1.0.0", generation: 52u64
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    let concurrentOne = spawn { concurrentV1.invoke("echo", "{\"value\":\"one\"}", identity: fixtureInvocationIdentity("concurrent-one")) }
    let concurrentTwo = spawn { concurrentV2.invoke("echo", "{\"value\":\"two\"}", identity: fixtureInvocationIdentity("concurrent-two")) }
    let concurrentResultOne = concurrentOne.get()
    let concurrentResultTwo = concurrentTwo.get()
    expect(match (concurrentResultOne) {
        case JavaScriptHostResult.Ok(value) => value.resultJson.contains("pi-fixed-v1") && value.resultJson.contains("one")
        case _ => false
    } && match (concurrentResultTwo) {
        case JavaScriptHostResult.Ok(value) => value.resultJson.contains("pi-fixed-ts-v2") && value.resultJson.contains("two")
        case _ => false
    }, "independent JavaScript sessions preserve generation and result isolation")
    concurrentV1.close()
    concurrentV2.close()
}
func piJavascriptApiContracts(): Unit {
    let root = canonicalize(Path("fixtures/upstream_pi_v0_87_1")).toString()
    let started = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root,
        "hello.ts",
        profile: JavaScriptHostLaunchProfile.PiV0871,
        extensionId: "pi.upstream.hello",
        extensionVersion: "0.87.1",
        generation: 1u64
    ))
    let host = match (started) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(host.tools.size == 1 && host.tools[0].name == "hello",
        "unmodified upstream Pi hello extension registers through the 0.87.1 API shim")
    expect(host.tools[0].inputSchemaJson.contains("\"required\":[\"name\"]"),
        "Pi Type.Object schema preserves the required tool argument")
    let result = match (host.invoke(
        "hello",
        "{\"name\":\"Axyndra\"}",
        identity: fixtureInvocationIdentity("pi-upstream-hello")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!result.isError && result.resultJson.contains("Hello, Axyndra!"),
        "Pi tool execution returns its upstream greeting")
    host.close()
}
// Pinned at pi v0.87.1 commit f07218c4d4bbc12bef056a7058c3dd49dfe41abe; ms source is v2.1.3.
func piNoUiDependencyContracts(): Unit {
    let root = canonicalize(Path("fixtures/upstream_pi_v0_87_1/with-deps")).toString()
    let started = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root,
        "index.ts",
        profile: JavaScriptHostLaunchProfile.PiV0871,
        extensionId: "pi.upstream.with-deps",
        extensionVersion: "0.87.1",
        generation: 2u64
    ))
    let host = match (started) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(host.tools.size == 1 && host.tools[0].name == "parse_duration",
        "upstream no-UI dependency extension registers through the Pi API shim")
    let result = match (host.invoke(
        "parse_duration",
        "{\"duration\":\"2 days\"}",
        identity: fixtureInvocationIdentity("pi-upstream-deps")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!result.isError && result.resultJson.contains("2 days = 172800000 milliseconds"),
        "upstream extension resolves its exact ms dependency and returns the parsed duration")
    let invalid = match (host.invoke(
        "parse_duration",
        "{\"duration\":\"fortnight\"}",
        identity: fixtureInvocationIdentity("pi-upstream-invalid")
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(invalid.isError && invalid.resultJson.contains("Invalid duration"),
        "upstream Pi tool exceptions become bounded tool errors")
    host.close()
}
func piSupportedEventContracts(): Unit {
    let root = canonicalize(Path("fixtures/upstream_pi_v0_87_1")).toString()
    let started = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root,
        "event-hooks.js",
        profile: JavaScriptHostLaunchProfile.PiV0871,
        extensionId: "pi.event.contract",
        extensionVersion: "0.87.1"
    ))
    let host = match (started) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(host.tools.isEmpty() && host.commands.isEmpty() && host.hooks.size == 2,
        "event-only Pi extensions register supported hook descriptors")
    expect(host.hooks[0].reference == "tool_call:0" &&
        host.hooks[1].reference == "tool_result:0",
        "event descriptors preserve registration order and stable references")

    let first = match (host.invoke(
        "tool_call:0",
        "{\"event\":{\"type\":\"tool_call\",\"toolCallId\":\"event-call-1\",\"toolName\":\"echo\",\"input\":{\"text\":\"first\"}}}",
        identity: JavaScriptHostInvocationIdentity(
            threadId: "thread-pi-event-contract", runId: "run-pi-event-1", epoch: 1,
            operationId: "", callId: "event-call-1", kind: "hook", commandId: "tool_call:0"
        )
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!first.isError && first.resultJson.contains("first:1"),
        "tool_call event handlers may mutate input and return it through the hook protocol")

    let second = match (host.invoke(
        "tool_call:0",
        "{\"event\":{\"type\":\"tool_call\",\"toolCallId\":\"event-call-2\",\"toolName\":\"echo\",\"input\":{\"text\":\"second\"}}}",
        identity: JavaScriptHostInvocationIdentity(
            threadId: "thread-pi-event-contract", runId: "run-pi-event-2", epoch: 1,
            operationId: "", callId: "event-call-2", kind: "hook", commandId: "tool_call:0"
        )
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(!second.isError && second.resultJson.contains("second:2"),
        "Pi event closure state persists within its active host process")

    let observed = match (host.invoke(
        "tool_result:0",
        "{\"event\":{\"type\":\"tool_result\",\"toolCallId\":\"event-result-1\",\"toolName\":\"echo\",\"input\":{},\"content\":[],\"isError\":false}}",
        identity: JavaScriptHostInvocationIdentity(
            threadId: "thread-pi-event-contract", runId: "run-pi-event-3", epoch: 1,
            operationId: "", callId: "event-result-1", kind: "hook", commandId: "tool_result:0"
        )
    )) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(observed.isError && observed.resultJson.contains("extension.pi_event_result_unsupported"),
        "tool_result handlers cannot replace a committed result")
    host.close()
}

func piUnsupportedApiContracts(): Unit {
    let root = canonicalize(Path("fixtures/upstream_pi_v0_87_1")).toString()
    let rejected = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root,
        "unsupported-api.js",
        profile: JavaScriptHostLaunchProfile.PiV0871,
        extensionId: "pi.unsupported.api",
        extensionVersion: "0.87.1"
    ))
    expect(match (rejected) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.pi_event_unsupported"
        case JavaScriptHostResult.Ok(host) =>
            host.close()
            false
    }, "unsupported Pi ExtensionAPI calls fail with a structured diagnostic")
}
func repeatedFixtureText(value: String, count: Int64): String {
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < count) {
        builder.append(value)
        index++
    }
    builder.toString()
}

func expectHandshakeFailure(root: String, mode: String, generation: UInt64): Unit {
    let started = startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_bad_handshake.js", extensionId: "pi.bad-handshake." + mode,
        extensionVersion: "1.0.0", generation: generation,
        grantedCapabilities: ["workspace.read"], defaultTimeoutMillis: 1000
    ))
    expect(match (started) {
        case JavaScriptHostResult.Err(error) => error.code == "extension.handshake_invalid"
        case _ => false
    }, "handshake rejects mismatched " + mode)
}

func startProtocolFaultHost(
    root: String,
    mode: String,
    generation: UInt64
): JavaScriptExtensionHost {
    match (startFixtureJavaScriptExtensionHost(JavaScriptHostLaunchRequest(
        root, "pi_protocol_faults.js", extensionId: "pi.protocol." + mode,
        extensionVersion: "1.0.0", generation: generation,
        grantedCapabilities: ["workspace.read"], defaultTimeoutMillis: 1000
    ))) {
        case JavaScriptHostResult.Ok(value) => value
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

func expectInvocationProtocolFailure(root: String, mode: String, expectedCode: String): Unit {
    let host = startProtocolFaultHost(root, mode, 80u64)
    let result = host.invoke(
        "echo", "{}", identity: fixtureInvocationIdentity("protocol-" + mode),
        timeoutMillis: 500
    )
    let actualCode = match (result) {
        case JavaScriptHostResult.Err(error) => error.code
        case _ => "unexpected_success"
    }
    let hostClosed = host.isClosed
    expect(actualCode == expectedCode && hostClosed,
        "IPC fixture " + mode + " expected " + expectedCode + ", got " +
            actualCode + ", closed=" + hostClosed.toString())
    host.close()
}

func fixtureContract(): Unit {
    let host = RecordingLifecycleHost()
    let runtime = ExtensionRuntime(host, probe: FakeProbe())
    expect(runtime.start(
        [CompiledExtensionProvider(
            "third-party.fixture", "embedded:third-party-fixture",
            fixtureExtensionManifest(), { => ThirdPartyFixtureExtension() }
        )],
        [ConfiguredExtension("third-party.fixture", required: true)]
    ).isOk(), "third-party SDK-only fixture validates and activates")
    expect(host.activeTools.toArray() == ["fixture_echo"], "fixture tool is registered through host lifecycle")
}

class FakeProbe <: RuntimeRequirementProbe {
    let available = ArrayList<String>()
    let unavailable = ArrayList<String>()
    public func executable(name: String): RequirementAvailability {
        if (available.contains(name)) { RequirementAvailability.Available }
        else if (unavailable.contains(name)) { RequirementAvailability.Unavailable }
        else { RequirementAvailability.Missing }
    }
}

class RecordingLifecycleHost <: ExtensionLifecycleHost {
    let activeTools = ArrayList<String>()
    let activationOrder = ArrayList<String>()
    let deactivationOrder = ArrayList<String>()
    var failDeactivationId: String = ""
    var throwDeactivationId: String = ""

    public func activate(extension: Extension, _source: String): HostLifecycleResult {
        let _ = _source
        let next = ArrayList<String>()
        for (tool in extension.tools()) {
            let name = tool.definition().name
            if (activeTools.contains(name) || next.contains(name)) {
                return HostLifecycleResult.Err("tool.duplicate", "tool already registered")
            }
            next.add(name)
        }
        for (name in next) { activeTools.add(name) }
        activationOrder.add(extension.metadata().id)
        HostLifecycleResult.Ok
    }

    public func deactivate(extensionId: String): HostLifecycleResult {
        deactivationOrder.add(extensionId)
        if (extensionId == throwDeactivationId) { throw IllegalStateException("injected host exception") }
        if (extensionId == failDeactivationId) {
            return HostLifecycleResult.Err("deactivate.failed", "injected deactivation failure")
        }
        if (extensionId == "axyndra.workspace-search") { remove(activeTools, "grep") }
        else if (extensionId == "axyndra.workspace-write") { remove(activeTools, "write") }
        else if (extensionId == "axyndra.ast") { remove(activeTools, "ast_grep"); remove(activeTools, "ast_edit") }
        else if (extensionId == "axyndra.web-search") { remove(activeTools, "web_search") }
        else if (extensionId == "third-party.fixture") { remove(activeTools, "fixture_echo") }
        HostLifecycleResult.Ok
    }
}

class StaticExtension <: Extension {
    private let id: String
    private let name: String
    private let version: String
    private let description: String
    private let values: Array<ExtensionTool>
    init(id: String, name: String, version: String, description: String, values: Array<ExtensionTool>) {
        this.id = id; this.name = name; this.version = version; this.description = description; this.values = values
    }
    public func metadata(): ExtensionMetadata { ExtensionMetadata(id, name, version, description) }
    public func tools(): Array<ExtensionTool> { values }
}

class StubTool <: ExtensionTool {
    private let name: String
    init(name: String) { this.name = name }
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(name, "Stub tool.", jsonObject([]), [workspaceRead()])
    }
    public func validate(input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.WorkspaceSearch(WorkspaceSearchIntent(invocation.callId)))
    }
    public func decode(_invocation: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func searchProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("axyndra.workspace-search", "embedded:search", workspaceSearchExtensionManifest(), { => WorkspaceSearchExtension() })
}

func writeProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("axyndra.workspace-write", "embedded:write", workspaceWriteExtensionManifest(), { => WorkspaceWriteExtension() })
}

func astProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("axyndra.ast", "embedded:ast", astExtensionManifest(), { => AstExtension() })
}

func webProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("axyndra.web-search", "embedded:web-search", webSearchExtensionManifest(), { => WebSearchExtension() })
}

func manifest(id: String, name: String, description: String, tools: Array<String>): String {
    let toolValues = ArrayList<JsonNode>()
    for (tool in tools) { toolValues.add(jsonString(tool)) }
    stringifyUnifiedJson(jsonObject([
        JsonObjectEntry("schemaVersion", jsonNumber("1")),
        JsonObjectEntry("id", jsonString(id)),
        JsonObjectEntry("name", jsonString(name)),
        JsonObjectEntry("version", jsonString("1.0.0")),
        JsonObjectEntry("description", jsonString(description)),
        JsonObjectEntry("sdk", jsonObject([
            JsonObjectEntry("min", jsonString("2.0.0")),
            JsonObjectEntry("maxExclusive", jsonString("3.0.0"))
        ])),
        JsonObjectEntry("tools", jsonArray(toolValues.toArray())),
        JsonObjectEntry("capabilities", jsonArray([jsonString("workspace.read")])),
        JsonObjectEntry("requirements", jsonObject([JsonObjectEntry("executables", jsonArray([]))]))
    ]))
}

func mustManifest(value: String): ExtensionManifest {
    match (parseExtensionManifest(value)) {
        case ExtensionRuntimeResult.Ok(manifest) => manifest
        case ExtensionRuntimeResult.Err(error) => throw IllegalStateException(error.message)
    }
}

func expectManifestFailure(value: String, message: String): Unit {
    expect(match (parseExtensionManifest(value)) {
        case ExtensionRuntimeResult.Err(_) => true
        case _ => false
    }, message)
}

func expectManifestKind(value: String, kind: ExtensionRuntimeErrorKind, message: String): Unit {
    expect(match (parseExtensionManifest(value)) {
        case ExtensionRuntimeResult.Err(error) => error.kind == kind
        case _ => false
    }, message)
}

func remove(values: ArrayList<String>, target: String): Unit {
    for (index in 0..values.size) {
        if (values[index] == target) { values.remove(at: index); return }
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
