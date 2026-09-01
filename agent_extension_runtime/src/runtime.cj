package agent_extension_runtime

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.env.*
import std.fs.*

public let EXTENSION_MANIFEST_SCHEMA_VERSION: Int64 = 1

@Derive[Equatable]
public enum ExtensionRuntimePhase {
    Discovery | Parse | Validation | Compatibility | RequirementCheck |
    Resolution | Registration | Activation | Deactivation
}

@Derive[Equatable]
public enum ExtensionRuntimeErrorKind {
    ManifestParse | ManifestValidation | ManifestSchemaUnsupported |
    ExtensionVersionMalformed | SdkRangeMalformed | SdkTooOld | SdkTooNew |
    RequirementMissing |
    RequirementUnavailable | DuplicateExtensionId | DuplicateTool |
    FactoryMissing | MetadataMismatch | Registration | Activation | Deactivation
}

public func extensionRuntimeErrorKindCode(kind: ExtensionRuntimeErrorKind): String {
    match (kind) {
        case ExtensionRuntimeErrorKind.ManifestParse => "manifest_parse"
        case ExtensionRuntimeErrorKind.ManifestValidation => "manifest_validation"
        case ExtensionRuntimeErrorKind.ManifestSchemaUnsupported => "manifest_schema_unsupported"
        case ExtensionRuntimeErrorKind.ExtensionVersionMalformed => "extension_version_malformed"
        case ExtensionRuntimeErrorKind.SdkRangeMalformed => "sdk_range_malformed"
        case ExtensionRuntimeErrorKind.SdkTooOld => "sdk_too_old"
        case ExtensionRuntimeErrorKind.SdkTooNew => "sdk_too_new"
        case ExtensionRuntimeErrorKind.RequirementMissing => "requirement_missing"
        case ExtensionRuntimeErrorKind.RequirementUnavailable => "requirement_unavailable"
        case ExtensionRuntimeErrorKind.DuplicateExtensionId => "duplicate_extension_id"
        case ExtensionRuntimeErrorKind.DuplicateTool => "duplicate_tool"
        case ExtensionRuntimeErrorKind.FactoryMissing => "factory_missing"
        case ExtensionRuntimeErrorKind.MetadataMismatch => "metadata_mismatch"
        case ExtensionRuntimeErrorKind.Registration => "registration"
        case ExtensionRuntimeErrorKind.Activation => "activation"
        case ExtensionRuntimeErrorKind.Deactivation => "deactivation"
    }
}

public class ExtensionRuntimeError <: Exception {
    public let kind: ExtensionRuntimeErrorKind
    public let phase: ExtensionRuntimePhase
    public let extensionId: String
    public let source: String
    public let field: String
    public let extensionVersion: String
    public let sdkMinimum: String
    public let sdkMaximumExclusive: String
    public let hostSdkVersion: String

    public init(
        kind: ExtensionRuntimeErrorKind,
        phase: ExtensionRuntimePhase,
        extensionId: String,
        source: String,
        message: String,
        field!: String = "",
        extensionVersion!: String = "",
        sdkMinimum!: String = "",
        sdkMaximumExclusive!: String = "",
        hostSdkVersion!: String = ""
    ) {
        super(message)
        this.kind = kind
        this.phase = phase
        this.extensionId = extensionId
        this.source = source
        this.field = field
        this.extensionVersion = extensionVersion
        this.sdkMinimum = sdkMinimum
        this.sdkMaximumExclusive = sdkMaximumExclusive
        this.hostSdkVersion = hostSdkVersion
    }
}

public enum ExtensionRuntimeResult<T> {
    Ok(T) | Err(ExtensionRuntimeError)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

public class SemanticVersion <: Equatable<SemanticVersion> {
    public let major: Int64
    public let minor: Int64
    public let patch: Int64

    public init(major: Int64, minor: Int64, patch: Int64) {
        if (major < 0 || minor < 0 || patch < 0) {
            throw IllegalArgumentException("version components must not be negative")
        }
        this.major = major
        this.minor = minor
        this.patch = patch
    }

    public operator func ==(other: SemanticVersion): Bool {
        major == other.major && minor == other.minor && patch == other.patch
    }

    public operator func !=(other: SemanticVersion): Bool { !(this == other) }

    public func lessThan(other: SemanticVersion): Bool {
        major < other.major ||
        (major == other.major && minor < other.minor) ||
        (major == other.major && minor == other.minor && patch < other.patch)
    }

    public func toString(): String { "${major}.${minor}.${patch}" }
}

public class SdkCompatibility {
    public let minimum: SemanticVersion
    public let maximumExclusive: SemanticVersion

    public init(minimum: SemanticVersion, maximumExclusive: SemanticVersion) {
        if (!minimum.lessThan(maximumExclusive)) {
            throw IllegalArgumentException("SDK compatibility range must not be empty")
        }
        this.minimum = minimum
        this.maximumExclusive = maximumExclusive
    }

    public func includes(version: SemanticVersion): Bool {
        !version.lessThan(minimum) && version.lessThan(maximumExclusive)
    }
}

public class ExtensionRequirements {
    public let executables: Array<String>
    public init(executables!: Array<String> = []) { this.executables = executables }
}

// Manifest is declarative only. It deliberately has no trust, approval,
// sandbox, prepared-operation, receipt, audit, or persistence fields.
public class ExtensionManifest {
    public let schemaVersion: Int64
    public let id: String
    public let name: String
    public let version: SemanticVersion
    public let description: String
    public let sdk: SdkCompatibility
    public let tools: Array<String>
    public let capabilities: Array<String>
    public let requirements: ExtensionRequirements

    public init(
        schemaVersion: Int64,
        id: String,
        name: String,
        version: SemanticVersion,
        description: String,
        sdk: SdkCompatibility,
        tools: Array<String>,
        capabilities: Array<String>,
        requirements: ExtensionRequirements
    ) {
        this.schemaVersion = schemaVersion
        this.id = id
        this.name = name
        this.version = version
        this.description = description
        this.sdk = sdk
        this.tools = tools
        this.capabilities = capabilities
        this.requirements = requirements
    }
}

public func parseExtensionManifest(
    document: String,
    source!: String = "embedded"
): ExtensionRuntimeResult<ExtensionManifest> {
    let value = try {
        parseUnifiedJson(document, maxBytes: 262144, maxDepth: 16)
    } catch (error: JsonException) {
        return runtimeError(
            ExtensionRuntimeErrorKind.ManifestParse,
            ExtensionRuntimePhase.Parse,
            "",
            source,
            error.message
        )
    }
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return validationError("", source, "", "manifest root must be an object")
    }
    let schemaVersion = match (requiredInteger(value, "schemaVersion")) {
        case ExtensionRuntimeResult.Err(error) => return withSource(error, source)
        case ExtensionRuntimeResult.Ok(number) => number
    }
    if (schemaVersion != EXTENSION_MANIFEST_SCHEMA_VERSION) {
        return runtimeError(
            ExtensionRuntimeErrorKind.ManifestSchemaUnsupported,
            ExtensionRuntimePhase.Compatibility,
            "",
            source,
            if (schemaVersion > EXTENSION_MANIFEST_SCHEMA_VERSION) {
                "future manifest schema ${schemaVersion} is unsupported; host supports ${EXTENSION_MANIFEST_SCHEMA_VERSION}"
            } else {
                "old manifest schema ${schemaVersion} is unsupported; host supports ${EXTENSION_MANIFEST_SCHEMA_VERSION}"
            },
            field: "schemaVersion"
        )
    }
    let id = match (requiredText(value, "id")) {
        case ExtensionRuntimeResult.Err(error) => return withSource(error, source)
        case ExtensionRuntimeResult.Ok(text) => text
    }
    if (!validExtensionId(id)) {
        return validationError(id, source, "id", "extension id is invalid")
    }
    let name = match (requiredText(value, "name")) {
        case ExtensionRuntimeResult.Err(error) => return withIdentity(error, id, source)
        case ExtensionRuntimeResult.Ok(text) => text
    }
    let description = match (requiredText(value, "description")) {
        case ExtensionRuntimeResult.Err(error) => return withIdentity(error, id, source)
        case ExtensionRuntimeResult.Ok(text) => text
    }
    let version = match (requiredVersion(
        value, "version", id, source,
        errorKind: ExtensionRuntimeErrorKind.ExtensionVersionMalformed
    )) {
        case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
        case ExtensionRuntimeResult.Ok(parsed) => parsed
    }
    let sdkValue = match (value.field("sdk")) {
        case Some(candidate) => candidate
        case None => return validationError(id, source, "sdk", "SDK compatibility is required")
    }
    if (sdkValue.unifiedKind != UnifiedJsonKind.Object) {
        return validationError(id, source, "sdk", "SDK compatibility must be an object")
    }
    let minimum = match (requiredVersion(
        sdkValue, "min", id, source,
        errorKind: ExtensionRuntimeErrorKind.SdkRangeMalformed
    )) {
        case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
        case ExtensionRuntimeResult.Ok(parsed) => parsed
    }
    let maximum = match (requiredVersion(
        sdkValue, "maxExclusive", id, source,
        errorKind: ExtensionRuntimeErrorKind.SdkRangeMalformed
    )) {
        case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
        case ExtensionRuntimeResult.Ok(parsed) => parsed
    }
    if (!minimum.lessThan(maximum)) {
        return runtimeError(
            ExtensionRuntimeErrorKind.SdkRangeMalformed,
            ExtensionRuntimePhase.Compatibility,
            id, source,
            "SDK compatibility requires min < maxExclusive",
            field: "sdk"
        )
    }
    let tools = match (requiredUniqueStrings(value, "tools", id, source, false)) {
        case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
        case ExtensionRuntimeResult.Ok(items) => items
    }
    let capabilities = match (requiredUniqueStrings(value, "capabilities", id, source, false)) {
        case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
        case ExtensionRuntimeResult.Ok(items) => items
    }
    for (capability in capabilities) {
        if (capability != "workspace.read" && capability != "workspace.write" &&
            capability != "network.http") {
            return validationError(id, source, "capabilities", "manifest capability is not part of the stable SDK taxonomy")
        }
    }
    let executables = match (value.field("requirements")) {
        case None => Array<String>()
        case Some(requirements) =>
            if (requirements.unifiedKind != UnifiedJsonKind.Object) {
                return validationError(id, source, "requirements", "requirements must be an object")
            } else {
                match (optionalUniqueStrings(requirements, "executables", id, source)) {
                    case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
                    case ExtensionRuntimeResult.Ok(items) => items
                }
            }
    }
    ExtensionRuntimeResult.Ok(ExtensionManifest(
        schemaVersion,
        id,
        name,
        version,
        description,
        SdkCompatibility(minimum, maximum),
        tools,
        capabilities,
        ExtensionRequirements(executables: executables)
    ))
}

@Derive[Equatable]
public enum RequirementAvailability { Available | Missing | Unavailable }

public interface RuntimeRequirementProbe {
    func executable(name: String): RequirementAvailability
}

public class PathRequirementProbe <: RuntimeRequirementProbe {
    public init() {}

    public func executable(name: String): RequirementAvailability {
        if (name.contains("/")) { return executablePathStatus(name) }
        match (getVariable("PATH")) {
            case None => RequirementAvailability.Missing
            case Some(path) =>
                for (directory in path.split(":")) {
                    let candidate = Path(directory).join(name).toString()
                    let status = executablePathStatus(candidate)
                    if (status == RequirementAvailability.Available) { return status }
                    if (status == RequirementAvailability.Unavailable) {
                        return RequirementAvailability.Unavailable
                    }
                }
                RequirementAvailability.Missing
        }
    }
}

public enum HostLifecycleResult {
    Ok | Err(String, String)
}

// Internal host boundary. It grants no authority to extensions; only the host
// composition root implements it.
public interface ExtensionLifecycleHost {
    func activate(extension: Extension, source: String): HostLifecycleResult
    func deactivate(extensionId: String): HostLifecycleResult
}

public class CompiledExtensionProvider {
    public let id: String
    public let source: String
    public let manifest: String
    private let factory: () -> Extension

    public init(id: String, source: String, manifest: String, factory: () -> Extension) {
        this.id = id.trimAscii()
        this.source = source.trimAscii()
        this.manifest = manifest
        this.factory = factory
    }

    public func create(): Extension { factory() }
}

public class ConfiguredExtension {
    public let id: String
    public let enabled: Bool
    public let required: Bool

    public init(id: String, enabled!: Bool = true, required!: Bool = false) {
        this.id = id.trimAscii()
        this.enabled = enabled
        this.required = required
    }
}

@Derive[Equatable]
public enum ExtensionLifecycleState {
    Discovered | Validated | Mounted | Active | StopAdmitting | Draining |
    Disposing | Inactive | Quarantined | Failed
}

public class ExtensionDiagnostic {
    public let id: String
    public let version: String
    public let state: ExtensionLifecycleState
    public let enabled: Bool
    public let compatible: Bool
    public let tools: Array<String>
    public let capabilities: Array<String>
    public let requirements: Array<String>
    public let error: ?ExtensionRuntimeError

    public init(
        id: String,
        version: String,
        state: ExtensionLifecycleState,
        enabled: Bool,
        compatible: Bool,
        tools: Array<String>,
        capabilities: Array<String>,
        requirements: Array<String>,
        error!: ?ExtensionRuntimeError = None
    ) {
        this.id = id
        this.version = version
        this.state = state
        this.enabled = enabled
        this.compatible = compatible
        this.tools = tools
        this.capabilities = capabilities
        this.requirements = requirements
        this.error = error
    }
}

class RuntimeRecord {
    let provider: CompiledExtensionProvider
    let manifest: ExtensionManifest
    let required: Bool
    var state: ExtensionLifecycleState
    var enabled: Bool
    var error: ?ExtensionRuntimeError

    init(
        provider: CompiledExtensionProvider,
        manifest: ExtensionManifest,
        required: Bool,
        state: ExtensionLifecycleState,
        enabled: Bool,
        error!: ?ExtensionRuntimeError = None
    ) {
        this.provider = provider
        this.manifest = manifest
        this.required = required
        this.state = state
        this.enabled = enabled
        this.error = error
    }
}

// Lifecycle calls are serialized by the host. In-flight ToolPipeline work is
// not owned or cancelled by this runtime.
public class ExtensionRuntime {
    private let host: ExtensionLifecycleHost
    private let probe: RuntimeRequirementProbe
    private let records = ArrayList<RuntimeRecord>()
    private let looseDiagnostics = ArrayList<ExtensionDiagnostic>()
    private var started = false
    private var stopping = false

    public init(
        host: ExtensionLifecycleHost,
        probe!: RuntimeRequirementProbe = PathRequirementProbe()
    ) {
        this.host = host
        this.probe = probe
    }

    public func start(
        providers: Array<CompiledExtensionProvider>,
        configured: Array<ConfiguredExtension>
    ): ExtensionRuntimeResult<Unit> {
        if (started) {
            return runtimeError(
                ExtensionRuntimeErrorKind.Activation,
                ExtensionRuntimePhase.Activation,
                "", "runtime", "extension runtime is already started"
            )
        }
        let ordered = orderProviders(providers)
        let configuredIds = ArrayList<String>()
        for (configuration in configured) {
            if (contains(configuredIds.toArray(), configuration.id)) {
                return runtimeError(
                    ExtensionRuntimeErrorKind.DuplicateExtensionId,
                    ExtensionRuntimePhase.Discovery,
                    configuration.id,
                    "host-config",
                    "duplicate configured extension id"
                )
            }
            configuredIds.add(configuration.id)
        }
        for (index in 1..ordered.size) {
            if (ordered[index - 1].id == ordered[index].id) {
                return runtimeError(
                    ExtensionRuntimeErrorKind.DuplicateExtensionId,
                    ExtensionRuntimePhase.Discovery,
                    ordered[index].id,
                    ordered[index].source,
                    "duplicate compiled extension id"
                )
            }
        }
        for (configuration in configured) {
            if (findProvider(ordered, configuration.id).isNone()) {
                let error = ExtensionRuntimeError(
                    ExtensionRuntimeErrorKind.FactoryMissing,
                    ExtensionRuntimePhase.Resolution,
                    configuration.id,
                    "compiled-catalog",
                    "configured extension has no compiled provider"
                )
                if (configuration.required) { return ExtensionRuntimeResult.Err(error) }
                looseDiagnostics.add(ExtensionDiagnostic(
                    configuration.id, "", ExtensionLifecycleState.Failed,
                    configuration.enabled, false, [], [], [], error: Some(error)
                ))
            }
        }
        for (provider in ordered) {
            let configuration = configuredValue(configured, provider.id)
            let enabled = match (configuration) {
                case Some(value) => value.enabled
                case None => false
            }
            let required = match (configuration) {
                case Some(value) => value.required
                case None => false
            }
            let parsed = parseExtensionManifest(provider.manifest, source: provider.source)
            let manifest = match (parsed) {
                case ExtensionRuntimeResult.Err(error) =>
                    if (required) { return ExtensionRuntimeResult.Err(error) }
                    else {
                        looseDiagnostics.add(ExtensionDiagnostic(
                            provider.id, "", ExtensionLifecycleState.Failed,
                            enabled, false, [], [], [], error: Some(error)
                        ))
                        continue
                    }
                case ExtensionRuntimeResult.Ok(value) => value
            }
            if (manifest.id != provider.id) {
                let error = ExtensionRuntimeError(
                    ExtensionRuntimeErrorKind.MetadataMismatch,
                    ExtensionRuntimePhase.Validation,
                    manifest.id,
                    provider.source,
                    "compiled provider id does not match manifest id",
                    field: "id"
                )
                if (required) { return ExtensionRuntimeResult.Err(error) }
                records.add(RuntimeRecord(provider, manifest, required, ExtensionLifecycleState.Failed, enabled, error: Some(error)))
                continue
            }
            let currentSdk = parseVersionUnchecked(AGENT_SDK_VERSION)
            if (!manifest.sdk.includes(currentSdk)) {
                let error = sdkCompatibilityError(manifest, provider.source, currentSdk)
                if (required) { return ExtensionRuntimeResult.Err(error) }
                records.add(RuntimeRecord(provider, manifest, required, ExtensionLifecycleState.Failed, enabled, error: Some(error)))
                continue
            }
            let record = RuntimeRecord(
                provider,
                manifest,
                required,
                if (enabled) { ExtensionLifecycleState.Validated } else { ExtensionLifecycleState.Inactive },
                enabled
            )
            records.add(record)
            if (enabled) {
                match (activateRecord(record)) {
                    case ExtensionRuntimeResult.Ok(_) => ()
                    case ExtensionRuntimeResult.Err(error) =>
                        if (required) { return ExtensionRuntimeResult.Err(error) }
                }
            }
        }
        started = true
        ExtensionRuntimeResult.Ok(())
    }

    public func activate(id: String): ExtensionRuntimeResult<Unit> {
        if (stopping) {
            return runtimeError(ExtensionRuntimeErrorKind.Activation, ExtensionRuntimePhase.Activation, id, "runtime", "extension runtime is stopping")
        }
        let record = match (findRecord(id)) {
            case Some(value) => value
            case None => return runtimeError(ExtensionRuntimeErrorKind.FactoryMissing, ExtensionRuntimePhase.Resolution, id, "runtime", "extension is not discovered")
        }
        if (record.state == ExtensionLifecycleState.Active) { return ExtensionRuntimeResult.Ok(()) }
        record.enabled = true
        activateRecord(record)
    }

    public func deactivate(id: String): ExtensionRuntimeResult<Unit> {
        let record = match (findRecord(id)) {
            case Some(value) => value
            case None => return runtimeError(ExtensionRuntimeErrorKind.FactoryMissing, ExtensionRuntimePhase.Resolution, id, "runtime", "extension is not discovered")
        }
        if (record.state == ExtensionLifecycleState.Inactive) { return ExtensionRuntimeResult.Ok(()) }
        if (record.state != ExtensionLifecycleState.Active) {
            return runtimeError(ExtensionRuntimeErrorKind.Deactivation, ExtensionRuntimePhase.Deactivation, id, record.provider.source, "extension is not active")
        }
        match (host.deactivate(id)) {
            case HostLifecycleResult.Ok =>
                record.enabled = false
                record.state = ExtensionLifecycleState.Inactive
                record.error = None
                ExtensionRuntimeResult.Ok(())
            case HostLifecycleResult.Err(code, message) =>
                let error = ExtensionRuntimeError(ExtensionRuntimeErrorKind.Deactivation, ExtensionRuntimePhase.Deactivation, id, record.provider.source, "${code}: ${message}")
                record.error = Some(error)
                ExtensionRuntimeResult.Err(error)
        }
    }

    public func shutdown(): ExtensionRuntimeResult<Unit> {
        if (stopping) { return ExtensionRuntimeResult.Ok(()) }
        stopping = true
        let ordered = diagnostics()
        for (diagnostic in ordered where diagnostic.state == ExtensionLifecycleState.Active) {
            match (deactivate(diagnostic.id)) {
                case ExtensionRuntimeResult.Ok(_) => ()
                case ExtensionRuntimeResult.Err(error) => return ExtensionRuntimeResult.Err(error)
            }
        }
        ExtensionRuntimeResult.Ok(())
    }

    public func diagnostics(): Array<ExtensionDiagnostic> {
        let values = ArrayList<ExtensionDiagnostic>()
        for (record in records) {
            values.add(ExtensionDiagnostic(
                record.manifest.id,
                record.manifest.version.toString(),
                record.state,
                record.enabled,
                record.manifest.sdk.includes(parseVersionUnchecked(AGENT_SDK_VERSION)),
                record.manifest.tools,
                record.manifest.capabilities,
                record.manifest.requirements.executables,
                error: record.error
            ))
        }
        for (diagnostic in looseDiagnostics) { values.add(diagnostic) }
        orderDiagnostics(values.toArray())
    }

    private func activateRecord(record: RuntimeRecord): ExtensionRuntimeResult<Unit> {
        for (name in record.manifest.requirements.executables) {
            let available = probe.executable(name)
            if (available != RequirementAvailability.Available) {
                let kind = if (available == RequirementAvailability.Missing) {
                    ExtensionRuntimeErrorKind.RequirementMissing
                } else {
                    ExtensionRuntimeErrorKind.RequirementUnavailable
                }
                let error = ExtensionRuntimeError(kind, ExtensionRuntimePhase.RequirementCheck, record.manifest.id, record.provider.source, "runtime executable requirement is unavailable: ${name}", field: name)
                record.state = ExtensionLifecycleState.Failed
                record.error = Some(error)
                return ExtensionRuntimeResult.Err(error)
            }
        }
        let extension = record.provider.create()
        match (validateRuntimeMetadata(record.manifest, extension, record.provider.source)) {
            case ExtensionRuntimeResult.Err(error) =>
                record.state = ExtensionLifecycleState.Failed
                record.error = Some(error)
                return ExtensionRuntimeResult.Err(error)
            case ExtensionRuntimeResult.Ok(_) => ()
        }
        match (host.activate(extension, record.provider.source)) {
            case HostLifecycleResult.Ok =>
                record.state = ExtensionLifecycleState.Active
                record.error = None
                ExtensionRuntimeResult.Ok(())
            case HostLifecycleResult.Err(code, message) =>
                let kind = if (code == "tool.duplicate") { ExtensionRuntimeErrorKind.DuplicateTool } else { ExtensionRuntimeErrorKind.Activation }
                let error = ExtensionRuntimeError(kind, ExtensionRuntimePhase.Activation, record.manifest.id, record.provider.source, "${code}: ${message}")
                record.state = ExtensionLifecycleState.Failed
                record.error = Some(error)
                ExtensionRuntimeResult.Err(error)
        }
    }

    private func findRecord(id: String): ?RuntimeRecord {
        for (record in records where record.manifest.id == id) { return Some(record) }
        None
    }
}

func validateRuntimeMetadata(
    manifest: ExtensionManifest,
    extension: Extension,
    source: String
): ExtensionRuntimeResult<Unit> {
    let metadata = extension.metadata()
    if (metadata.id != manifest.id || metadata.name != manifest.name ||
        metadata.version != manifest.version.toString() ||
        metadata.description != manifest.description) {
        return runtimeError(ExtensionRuntimeErrorKind.MetadataMismatch, ExtensionRuntimePhase.Validation, manifest.id, source, "manifest and extension metadata differ")
    }
    let toolNames = ArrayList<String>()
    let capabilities = ArrayList<String>()
    for (tool in extension.tools()) {
        let definition = tool.definition()
        toolNames.add(definition.name)
        for (capability in definition.capabilities) {
            addUnique(capabilities, capability.name)
            if (!contains(manifest.capabilities, capability.name)) {
                return runtimeError(ExtensionRuntimeErrorKind.ManifestValidation, ExtensionRuntimePhase.Validation, manifest.id, source, "tool requires undeclared manifest capability: ${capability.name}", field: "capabilities")
            }
        }
    }
    if (!sameStrings(toolNames.toArray(), manifest.tools)) {
        return runtimeError(ExtensionRuntimeErrorKind.MetadataMismatch, ExtensionRuntimePhase.Validation, manifest.id, source, "manifest and extension tool declarations differ", field: "tools")
    }
    ExtensionRuntimeResult.Ok(())
}

func executablePathStatus(path: String): RequirementAvailability {
    if (!exists(Path(path))) { return RequirementAvailability.Missing }
    try {
        let info = FileInfo(Path(path))
        if (info.isRegular() && info.canExecute()) {
            RequirementAvailability.Available
        } else {
            RequirementAvailability.Unavailable
        }
    } catch (_: Exception) {
        RequirementAvailability.Unavailable
    }
}

func parseVersionUnchecked(value: String): SemanticVersion {
    let parts = value.split(".")
    SemanticVersion(Int64.parse(parts[0]), Int64.parse(parts[1]), Int64.parse(parts[2]))
}

func requiredVersion(
    value: JsonNode,
    name: String,
    id: String,
    source: String,
    errorKind!: ExtensionRuntimeErrorKind = ExtensionRuntimeErrorKind.ExtensionVersionMalformed
): ExtensionRuntimeResult<SemanticVersion> {
    let text = match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Text && field.text != "" &&
            field.text == field.text.trimAscii()) {
            field.text
        } else {
            return versionError(errorKind, id, source, name)
        }
        case None => return versionError(errorKind, id, source, name)
    }
    let parts = text.split(".")
    if (parts.size != 3) { return versionError(errorKind, id, source, name) }
    try {
        for (part in parts) {
            let number = Int64.parse(part)
            if (number < 0 || number.toString() != part) {
                return versionError(errorKind, id, source, name)
            }
        }
        ExtensionRuntimeResult.Ok(SemanticVersion(Int64.parse(parts[0]), Int64.parse(parts[1]), Int64.parse(parts[2])))
    } catch (_: Exception) {
        versionError(errorKind, id, source, name)
    }
}

func versionError(
    kind: ExtensionRuntimeErrorKind,
    id: String,
    source: String,
    field: String
): ExtensionRuntimeResult<SemanticVersion> {
    runtimeError(
        kind,
        ExtensionRuntimePhase.Compatibility,
        id, source,
        "version must use canonical non-negative MAJOR.MINOR.PATCH decimal syntax",
        field: field
    )
}

func sdkCompatibilityError(
    manifest: ExtensionManifest,
    source: String,
    host: SemanticVersion
): ExtensionRuntimeError {
    let kind = if (host.lessThan(manifest.sdk.minimum)) {
        ExtensionRuntimeErrorKind.SdkTooOld
    } else {
        ExtensionRuntimeErrorKind.SdkTooNew
    }
    ExtensionRuntimeError(
        kind,
        ExtensionRuntimePhase.Compatibility,
        manifest.id,
        source,
        "extension ${manifest.id}@${manifest.version.toString()} requires agent_sdk " +
            ">=${manifest.sdk.minimum.toString()} <${manifest.sdk.maximumExclusive.toString()}, " +
            "host provides ${host.toString()}",
        field: "sdk",
        extensionVersion: manifest.version.toString(),
        sdkMinimum: manifest.sdk.minimum.toString(),
        sdkMaximumExclusive: manifest.sdk.maximumExclusive.toString(),
        hostSdkVersion: host.toString()
    )
}

func requiredText(value: JsonNode, name: String): ExtensionRuntimeResult<String> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == UnifiedJsonKind.Text && field.text.trimAscii() != "") {
                ExtensionRuntimeResult.Ok(field.text.trimAscii())
            } else {
                validationError("", "", name, "${name} must be a non-empty string")
            }
        case None => validationError("", "", name, "${name} is required")
    }
}

func requiredInteger(value: JsonNode, name: String): ExtensionRuntimeResult<Int64> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != UnifiedJsonKind.Number) {
                validationError("", "", name, "${name} must be an integer")
            } else {
                try { ExtensionRuntimeResult.Ok(Int64.parse(field.number)) }
                catch (_: Exception) { validationError("", "", name, "${name} must be an integer") }
            }
        case None => validationError("", "", name, "${name} is required")
    }
}

func requiredUniqueStrings(value: JsonNode, name: String, id: String, source: String, allowEmpty: Bool): ExtensionRuntimeResult<Array<String>> {
    match (value.field(name)) {
        case None => validationError(id, source, name, "${name} is required")
        case Some(field) => parseUniqueStrings(field, name, id, source, allowEmpty)
    }
}

func optionalUniqueStrings(value: JsonNode, name: String, id: String, source: String): ExtensionRuntimeResult<Array<String>> {
    match (value.field(name)) {
        case None => ExtensionRuntimeResult.Ok([])
        case Some(field) => parseUniqueStrings(field, name, id, source, true)
    }
}

func parseUniqueStrings(value: JsonNode, name: String, id: String, source: String, allowEmpty: Bool): ExtensionRuntimeResult<Array<String>> {
    if (value.unifiedKind != UnifiedJsonKind.List) { return validationError(id, source, name, "${name} must be an array") }
    let values = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Text || item.text.trimAscii() == "") {
            return validationError(id, source, name, "${name} must contain non-empty strings")
        }
        if (item.text.contains("\u{0000}")) {
            return validationError(id, source, name, "${name} contains NUL")
        }
        if (contains(values.toArray(), item.text.trimAscii())) {
            return validationError(id, source, name, "${name} contains a duplicate declaration")
        }
        values.add(item.text.trimAscii())
    }
    if (!allowEmpty && values.isEmpty()) { return validationError(id, source, name, "${name} must not be empty") }
    ExtensionRuntimeResult.Ok(values.toArray())
}

func validExtensionId(value: String): Bool {
    if (value == "" || !value.contains(".")) { return false }
    for (byte in value.toArray()) {
        let lower = byte >= UInt8(97) && byte <= UInt8(122)
        let digit = byte >= UInt8(48) && byte <= UInt8(57)
        if (!lower && !digit && byte != UInt8(45) && byte != UInt8(46)) { return false }
    }
    true
}

func orderProviders(values: Array<CompiledExtensionProvider>): Array<CompiledExtensionProvider> {
    let ordered = ArrayList<CompiledExtensionProvider>()
    for (value in values) {
        var inserted = false
        for (index in 0..ordered.size) {
            if (value.id < ordered[index].id) {
                ordered.add(value, at: index)
                inserted = true
                break
            }
        }
        if (!inserted) { ordered.add(value) }
    }
    ordered.toArray()
}

func orderDiagnostics(values: Array<ExtensionDiagnostic>): Array<ExtensionDiagnostic> {
    let ordered = ArrayList<ExtensionDiagnostic>()
    for (value in values) {
        var inserted = false
        for (index in 0..ordered.size) {
            if (value.id < ordered[index].id) {
                ordered.add(value, at: index)
                inserted = true
                break
            }
        }
        if (!inserted) { ordered.add(value) }
    }
    ordered.toArray()
}

func findProvider(values: Array<CompiledExtensionProvider>, id: String): ?CompiledExtensionProvider {
    for (value in values where value.id == id) { return Some(value) }
    None
}

func configuredValue(values: Array<ConfiguredExtension>, id: String): ?ConfiguredExtension {
    for (value in values where value.id == id) { return Some(value) }
    None
}

func sameStrings(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (value in left where !contains(right, value)) { return false }
    true
}

func contains(values: Array<String>, value: String): Bool {
    for (item in values where item == value) { return true }
    false
}

func addUnique(values: ArrayList<String>, value: String): Unit {
    if (!contains(values.toArray(), value)) { values.add(value) }
}

func validationError<T>(id: String, source: String, field: String, message: String): ExtensionRuntimeResult<T> {
    runtimeError(ExtensionRuntimeErrorKind.ManifestValidation, ExtensionRuntimePhase.Validation, id, source, message, field: field)
}

func runtimeError<T>(kind: ExtensionRuntimeErrorKind, phase: ExtensionRuntimePhase, id: String, source: String, message: String, field!: String = ""): ExtensionRuntimeResult<T> {
    ExtensionRuntimeResult.Err(ExtensionRuntimeError(kind, phase, id, source, message, field: field))
}

func withSource<T>(error: ExtensionRuntimeError, source: String): ExtensionRuntimeResult<T> {
    ExtensionRuntimeResult.Err(ExtensionRuntimeError(error.kind, error.phase, error.extensionId, source, error.message, field: error.field))
}

func withIdentity<T>(error: ExtensionRuntimeError, id: String, source: String): ExtensionRuntimeResult<T> {
    ExtensionRuntimeResult.Err(ExtensionRuntimeError(error.kind, error.phase, id, source, error.message, field: error.field))
}
