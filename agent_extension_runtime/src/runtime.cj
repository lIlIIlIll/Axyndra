package agent_extension_runtime

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.convert.*
import std.deriving.*

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

@Derive[Equatable]
public enum ExtensionLifecycleState {
    Discovered | Validated | Mounted | Active | StopAdmitting | Draining |
    Disposing | Inactive | Quarantined | Failed
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

func runtimeError<T>(kind: ExtensionRuntimeErrorKind, phase: ExtensionRuntimePhase, id: String, source: String, message: String, field!: String = ""): ExtensionRuntimeResult<T> {
    ExtensionRuntimeResult.Err(ExtensionRuntimeError(kind, phase, id, source, message, field: field))
}
