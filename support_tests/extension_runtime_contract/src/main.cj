package extension_runtime_contract

import agent_sdk.*
import agent_extension_runtime.*
import json4cj.*
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
    migratedFirstPartyContracts()
    fixtureContract()
    println("extension manifest/runtime contract passed")
    0
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
        [ConfiguredExtension("omp.web-search"), ConfiguredExtension("omp.ast")]
    ).isOk(), "migrated first-party extensions activate through the canonical runtime")
    expect(host.activationOrder.toArray() == ["omp.ast", "omp.web-search"],
        "migrated first-party activation order is deterministic")
    expect(host.activeTools.contains("ast_grep") && host.activeTools.contains("ast_edit") &&
        host.activeTools.contains("web_search"), "migrated tools are registered by lifecycle host")

    let unavailable = ExtensionRuntime(RecordingLifecycleHost(), probe: FakeProbe())
    expect(unavailable.start(
        [astProvider(), webProvider()],
        [ConfiguredExtension("omp.ast"), ConfiguredExtension("omp.web-search")]
    ).isOk(), "missing requirements on optional extensions do not fail product startup")
    expect(unavailable.diagnostics()[0].state == ExtensionLifecycleState.Failed &&
        unavailable.diagnostics()[1].state == ExtensionLifecycleState.Failed,
        "optional requirement failures remain explicit diagnostics")
}

func manifestContracts(): Unit {
    let valid = workspaceSearchExtensionManifest()
    let parsed = mustManifest(valid)
    expect(parsed.schemaVersion == 1 && parsed.id == "omp.workspace-search", "valid manifest parses")
    expect(parsed.sdk.includes(SemanticVersion(1, 1, 0)), "current SDK is compatible")
    expect(parseExtensionManifest(valid.replace(
        "\"requirements\":", "\"futureOptional\": true, \"requirements\":"
    )).isOk(), "unknown optional top-level fields are tolerated")

    expectManifestKind(valid.replace("\"schemaVersion\": 1", "\"schemaVersion\": 0"),
        ExtensionRuntimeErrorKind.ManifestSchemaUnsupported, "unsupported old schema is rejected")
    expectManifestKind(valid.replace("\"schemaVersion\": 1", "\"schemaVersion\": 2"),
        ExtensionRuntimeErrorKind.ManifestSchemaUnsupported, "future schema is rejected")

    expectManifestFailure(valid.replace("\"id\": \"omp.workspace-search\",", ""), "missing id")
    expectManifestFailure(valid.replace("omp.workspace-search", "Invalid Id"), "invalid id")
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
            ConfiguredExtension("omp.workspace-write", required: true),
            ConfiguredExtension("omp.workspace-search", required: true)
        ]
    ).isOk(), "built-in extensions activate")
    expect(host.activationOrder.toArray() == ["omp.workspace-search", "omp.workspace-write"], "registration order is lexical and deterministic")
    let diagnostics = runtime.diagnostics()
    expect(diagnostics.size == 2 && diagnostics[0].state == ExtensionLifecycleState.Active, "active diagnostics are deterministic")
    expect(diagnostics[0].tools == ["grep"] && diagnostics[0].capabilities == ["workspace.read"] && diagnostics[0].requirements == ["rg"], "diagnostics project declarations")
    expect(runtime.deactivate("omp.workspace-search").isOk(), "deactivation succeeds")
    expect(runtime.deactivate("omp.workspace-search").isOk(), "double deactivation is idempotent")
    expect(!host.activeTools.contains("grep"), "inactive extension tool is unavailable")
    expect(runtime.activate("omp.workspace-search").isOk(), "inactive extension reactivates")

    let duplicate = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(match (duplicate.start(
        [searchProvider(), searchProvider()],
        [ConfiguredExtension("omp.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.DuplicateExtensionId
        case _ => false
    }, "duplicate compiled IDs fail closed")

    let missingProbe = FakeProbe()
    let missing = ExtensionRuntime(RecordingLifecycleHost(), probe: missingProbe)
    expect(match (missing.start(
        [searchProvider()],
        [ConfiguredExtension("omp.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.RequirementMissing
        case _ => false
    }, "missing required executable fails required startup")

    let unavailableProbe = FakeProbe()
    unavailableProbe.unavailable.add("rg")
    let unavailable = ExtensionRuntime(RecordingLifecycleHost(), probe: unavailableProbe)
    expect(match (unavailable.start(
        [searchProvider()],
        [ConfiguredExtension("omp.workspace-search", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.RequirementUnavailable
        case _ => false
    }, "present but non-executable requirement is unavailable")

    let optional = ExtensionRuntime(RecordingLifecycleHost(), probe: missingProbe)
    expect(optional.start(
        [searchProvider(), writeProvider()],
        [
            ConfiguredExtension("omp.workspace-search"),
            ConfiguredExtension("omp.workspace-write", enabled: false)
        ]
    ).isOk(), "optional failure and disabled extension do not fail startup")
    expect(optional.diagnostics()[0].state == ExtensionLifecycleState.Failed && optional.diagnostics()[1].state == ExtensionLifecycleState.Inactive, "optional failure and disabled reasons remain diagnostic")

    let futureManifest = workspaceWriteExtensionManifest().replace(
        "\"min\": \"1.0.0\"", "\"min\": \"2.0.0\""
    ).replace("\"maxExclusive\": \"2.0.0\"", "\"maxExclusive\": \"3.0.0\"")
    let incompatible = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    expect(match (incompatible.start(
        [CompiledExtensionProvider("omp.workspace-write", "future", futureManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("omp.workspace-write", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) =>
            error.kind == ExtensionRuntimeErrorKind.SdkTooOld &&
            error.phase == ExtensionRuntimePhase.Compatibility &&
            error.extensionId == "omp.workspace-write" &&
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
        [CompiledExtensionProvider("omp.workspace-write", "old-range", exactMaxManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("omp.workspace-write", required: true)]
    )) {
        case ExtensionRuntimeResult.Err(error) => error.kind == ExtensionRuntimeErrorKind.SdkTooNew
        case _ => false
    }, "host at maxExclusive is rejected")

    let optionalIncompatibleHost = RecordingLifecycleHost()
    let optionalIncompatible = ExtensionRuntime(optionalIncompatibleHost, probe: probe)
    expect(optionalIncompatible.start(
        [CompiledExtensionProvider("omp.workspace-write", "future-optional", futureManifest, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("omp.workspace-write")]
    ).isOk(), "optional incompatible extension does not abort startup")
    expect(optionalIncompatibleHost.activeTools.isEmpty() &&
        optionalIncompatible.diagnostics()[0].state == ExtensionLifecycleState.Failed &&
        !optionalIncompatible.diagnostics()[0].compatible,
        "optional incompatibility exposes diagnostics and zero tools")

    let mismatch = ExtensionRuntime(RecordingLifecycleHost(), probe: probe)
    let drift = workspaceWriteExtensionManifest().replace("\"version\": \"1.0.0\"", "\"version\": \"1.0.1\"")
    expect(match (mismatch.start(
        [CompiledExtensionProvider("omp.workspace-write", "drift", drift, { => WorkspaceWriteExtension() })],
        [ConfiguredExtension("omp.workspace-write", required: true)]
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
        if (extensionId == "omp.workspace-search") { remove(activeTools, "grep") }
        else if (extensionId == "omp.workspace-write") { remove(activeTools, "write") }
        else if (extensionId == "omp.ast") { remove(activeTools, "ast_grep"); remove(activeTools, "ast_edit") }
        else if (extensionId == "omp.web-search") { remove(activeTools, "web_search") }
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
        ExtensionToolDefinition(name, "Stub tool.", JsonValue.objectValue([]), [workspaceRead()])
    }
    public func validate(input: JsonValue): SdkResult<JsonValue> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.WorkspaceSearch(WorkspaceSearchIntent(invocation.callId)))
    }
    public func decode(_invocation: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func searchProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("omp.workspace-search", "embedded:search", workspaceSearchExtensionManifest(), { => WorkspaceSearchExtension() })
}

func writeProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("omp.workspace-write", "embedded:write", workspaceWriteExtensionManifest(), { => WorkspaceWriteExtension() })
}

func astProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("omp.ast", "embedded:ast", astExtensionManifest(), { => AstExtension() })
}

func webProvider(): CompiledExtensionProvider {
    CompiledExtensionProvider("omp.web-search", "embedded:web-search", webSearchExtensionManifest(), { => WebSearchExtension() })
}

func manifest(id: String, name: String, description: String, tools: Array<String>): String {
    let toolValues = ArrayList<JsonValue>()
    for (tool in tools) { toolValues.add(JsonValue.stringValue(tool)) }
    encodeJson(JsonValue.objectValue([
        JsonField("schemaVersion", JsonValue.numberValue("1")),
        JsonField("id", JsonValue.stringValue(id)),
        JsonField("name", JsonValue.stringValue(name)),
        JsonField("version", JsonValue.stringValue("1.0.0")),
        JsonField("description", JsonValue.stringValue(description)),
        JsonField("sdk", JsonValue.objectValue([
            JsonField("min", JsonValue.stringValue("1.0.0")),
            JsonField("maxExclusive", JsonValue.stringValue("2.0.0"))
        ])),
        JsonField("tools", JsonValue.arrayValue(toolValues.toArray())),
        JsonField("capabilities", JsonValue.arrayValue([JsonValue.stringValue("workspace.read")])),
        JsonField("requirements", JsonValue.objectValue([JsonField("executables", JsonValue.arrayValue([]))]))
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
