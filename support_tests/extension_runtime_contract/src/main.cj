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

main(): Int64 {
    versionContracts()
    manifestContracts()
    runtimeContracts()
    safeLifecycleContracts()
    migratedFirstPartyContracts()
    fixtureContract()
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
    public func mount(_provider: CompiledExtensionProvider, generation: UInt64): HostLifecycleResult {
        let _ = _provider
        events.add("mount:${generation}")
        HostLifecycleResult.Ok
    }
    public func activate(_extensionId: String, generation: UInt64): HostLifecycleResult {
        let _ = _extensionId
        events.add("activate:${generation}")
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
        astManifest.sdk.minimum == SemanticVersion(1, 1, 0) &&
        astManifest.sdk.maximumExclusive == SemanticVersion(1, 2, 0),
        "AST manifest declares static tools, authority requirements, and executable")
    expect(webManifest.tools == ["web_search"] && webManifest.capabilities == ["network.http"] &&
        webManifest.requirements.executables == ["curl"] &&
        webManifest.sdk.minimum == SemanticVersion(1, 1, 0) &&
        webManifest.sdk.maximumExclusive == SemanticVersion(1, 2, 0),
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
    expect(parsed.sdk.includes(SemanticVersion(1, 1, 0)), "current SDK is compatible")
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
    expectManifestKind(valid.replace("\"min\": \"1.0.0\"", "\"min\": \"2.0.0\""),
        ExtensionRuntimeErrorKind.SdkRangeMalformed, "empty SDK range is rejected")
    expectManifestFailure(valid.replace("\"tools\": [\"grep\"]", "\"tools\": [\"grep\", \"grep\"]"), "duplicate tool declaration")
    expectManifestFailure(valid.replace("\"capabilities\": [\"workspace.read\"]", "\"capabilities\": [\"workspace.read\", \"workspace.read\"]"), "duplicate capability declaration")
    expectManifestFailure("{", "malformed JSON")
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
        "\"min\": \"1.0.0\"", "\"min\": \"2.0.0\""
    ).replace("\"maxExclusive\": \"2.0.0\"", "\"maxExclusive\": \"3.0.0\"")
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
            error.sdkMinimum == "2.0.0" && error.sdkMaximumExclusive == "3.0.0" &&
            error.hostSdkVersion == AGENT_SDK_VERSION
        case _ => false
    }, "future SDK range is rejected before activation with structured context")
    let exactMaxManifest = workspaceWriteExtensionManifest().replace(
        "\"maxExclusive\": \"2.0.0\"", "\"maxExclusive\": \"1.1.0\""
    )
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
            JsonObjectEntry("min", jsonString("1.0.0")),
            JsonObjectEntry("maxExclusive", jsonString("2.0.0"))
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
