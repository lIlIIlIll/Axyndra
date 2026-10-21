package agent_extension_runtime

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.fs.*
import agent_domain.*
import agent_sdk.*
import std.sort.*
import stdx.crypto.digest.*

@Derive[Equatable]
public enum PluginManifestFamily { Pi | Codex | Axyndra }

@Derive[Equatable]
public enum PluginEcosystem { Pi | Codex | Axyndra }

@Derive[Equatable]
public enum PluginEntryKind { JavaScript | NativeExecutable | LegacyProcess }

@Derive[Equatable]
public enum PluginComponentKind { Skill | Mcp | Prompt | Extension | Hook | Command | Theme | HostedOnly }

@Derive[Equatable]
public enum PluginComponentStatus { Supported | Blocked | Unsupported | Unverified }

public class PluginPackageError {
    public let code: String
    public let message: String
    public let source: String
    public let field: String

    public init(code: String, message: String, source!: String = "", field!: String = "") {
        this.code = code
        this.message = message
        this.source = source
        this.field = field
    }
}

public enum PluginPackageResult<T> {
    Ok(T) | Err(PluginPackageError)

    public func isOk(): Bool {
        match (this) {
            case Ok(_) => true
            case Err(_) => false
        }
    }
}

public class PluginComponent {
    public let kind: PluginComponentKind
    public let relativePath: String
    public let status: PluginComponentStatus
    public let name: String
    public let identity: String
    public let dependencies: Array<String>

    public init(
        kind: PluginComponentKind,
        relativePath: String,
        status!: PluginComponentStatus = PluginComponentStatus.Supported,
        name!: String = "",
        identity!: String = "",
        dependencies!: Array<String> = []
    ) {
        if (relativePath.trimAscii() == "") {
            throw IllegalArgumentException("plugin component path must not be empty")
        }
        this.kind = kind
        this.relativePath = relativePath.trimAscii()
        this.status = status
        this.name = if (name.trimAscii() == "") { this.relativePath } else { name.trimAscii() }
        this.identity = identity.trimAscii()
        this.dependencies = dependencies
    }
}

public class PluginPackageDependency {
    public let name: String
    public let versionRange: String
    public let optional: Bool
    public let development: Bool

    public init(name: String, versionRange: String, optional!: Bool = false, development!: Bool = false) {
        this.name = name.trimAscii()
        this.versionRange = versionRange.trimAscii()
        this.optional = optional
        this.development = development
    }
}

public class PluginHookDeclaration {
    public let event: String
    public let matcher: String
    public let command: String
    public let timeoutMillis: Int64

    public init(event: String, matcher: String, command: String, timeoutMillis: Int64) {
        if ((event != "PreToolUse" && event != "PostToolUse") ||
            matcher.trimAscii() == "" || command.trimAscii() == "" ||
            timeoutMillis < 1 || timeoutMillis > 30000) {
            throw IllegalArgumentException("Codex hook declaration is invalid")
        }
        this.event = event
        this.matcher = matcher.trimAscii()
        this.command = command
        this.timeoutMillis = timeoutMillis
    }
}

class PluginCodexLayout {
    let components: Array<PluginComponent>
    let overlayPath: String
    let hookDeclarations: Array<PluginHookDeclaration>

    init(
        components: Array<PluginComponent>,
        overlayPath: String,
        hookDeclarations!: Array<PluginHookDeclaration> = []
    ) {
        this.components = components
        this.overlayPath = overlayPath
        this.hookDeclarations = hookDeclarations
    }
}

public class PluginPackageDescriptor {
    public let id: String
    public let namespace: String
    public let version: String
    public let ecosystem: PluginEcosystem
    public let family: PluginManifestFamily
    public let source: String
    public let root: String
    public let manifestPath: String
    public let overlayPath: String
    public let compatibilityProfile: String
    public let components: Array<PluginComponent>
    public let hookDeclarations: Array<PluginHookDeclaration>
    public let dependencies: Array<PluginPackageDependency>
    private let componentDependencyValues: Array<PluginContributionDependency>
    public prop componentDependencies: Array<PluginContributionDependency> {
        get() { componentDependencyValues.clone() }
    }
    public let missingDependencies: Array<String>
    public let entrypoint: String
    public let entryKind: PluginEntryKind
    public let contributions: Array<PluginContributionDefinition>
    public let requestedCapabilities: Array<String>
    public let sdkRange: String
    public let protocolRange: String
    public let contentDigest: String
    public let declaredContentDigest: String
    public let signature: String

    public init(
        id: String,
        version: String,
        ecosystem: PluginEcosystem,
        family: PluginManifestFamily,
        source: String,
        root!: String = "",
        manifestPath!: String = "",
        overlayPath!: String = "",
        compatibilityProfile!: String = "",
        components!: Array<PluginComponent> = [],
        hookDeclarations!: Array<PluginHookDeclaration> = [],
        dependencies!: Array<PluginPackageDependency> = [],
        componentDependencies!: Array<PluginContributionDependency> = [],
        missingDependencies!: Array<String> = [],
        entrypoint!: String = "",
        requestedCapabilities!: Array<String> = [],
        sdkRange!: String = "",
        protocolRange!: String = "axyndra-extension-v1",
        contentDigest!: String = "",
        declaredContentDigest!: String = "",
        signature!: String = "",
        entryKind!: PluginEntryKind = PluginEntryKind.LegacyProcess,
        contributions!: Array<PluginContributionDefinition> = []
    ) {
        this.id = id.trimAscii()
        this.namespace = pluginPackageNamespace(ecosystem, this.id)
        this.version = version.trimAscii()
        this.ecosystem = ecosystem
        this.family = family
        this.source = source.trimAscii()
        this.root = root.trimAscii()
        this.manifestPath = manifestPath.trimAscii()
        this.overlayPath = overlayPath.trimAscii()
        this.compatibilityProfile = if (compatibilityProfile.trimAscii() == "") {
            pluginDefaultCompatibilityProfile(family)
        } else {
            compatibilityProfile.trimAscii()
        }
        this.components = pluginNamespaceComponents(this.namespace, components)
        this.hookDeclarations = hookDeclarations
        this.dependencies = dependencies
        if (componentDependencies.size > 32) { throw IllegalArgumentException("plugin component dependency limit exceeded") }
        this.componentDependencyValues = componentDependencies.clone()
        this.missingDependencies = missingDependencies
        this.entrypoint = entrypoint.trimAscii()
        this.entryKind = if (ecosystem == PluginEcosystem.Axyndra) { entryKind }
            else { PluginEntryKind.JavaScript }
        this.contributions = contributions.clone()
        this.requestedCapabilities = requestedCapabilities
        this.sdkRange = sdkRange.trimAscii()
        this.protocolRange = protocolRange.trimAscii()
        this.contentDigest = contentDigest.trimAscii()
        this.declaredContentDigest = declaredContentDigest.trimAscii()
        this.signature = signature.trimAscii()
    }
}
public func pluginEntryKindName(kind: PluginEntryKind): String {
    match (kind) {
        case PluginEntryKind.JavaScript => "javascript"
        case PluginEntryKind.NativeExecutable => "native-executable"
        case PluginEntryKind.LegacyProcess => "legacy-process"
    }
}

public func pluginContributionKindName(kind: PluginContributionKind): String {
    match (kind) {
        case PluginContributionKind.Tool => "tool"
        case PluginContributionKind.Command => "command"
        case PluginContributionKind.View => "view"
        case PluginContributionKind.Skill => "skill"
        case PluginContributionKind.Provider => "provider"
        case PluginContributionKind.ModelProvider => "model_provider"
        case PluginContributionKind.ContextProvider => "context_provider"
        case PluginContributionKind.ResourceProvider => "resource_provider"
        case PluginContributionKind.Event => "event"
        case PluginContributionKind.Service => "service"
    }
}

// Inspection is metadata only: this serializer never initializes the package
// or exposes signature bytes. Runtime readiness remains an activation result.
public func pluginPackageDiagnosticValue(descriptor: PluginPackageDescriptor): JsonNode {
    let contributions = ArrayList<JsonNode>()
    for (contribution in descriptor.contributions) {
        let kind = pluginContributionKindName(contribution.kind)
        contributions.add(jsonObject([
            JsonObjectEntry("kind", jsonString(kind)),
            JsonObjectEntry("name", jsonString(contribution.name)),
            JsonObjectEntry("identity", jsonString(descriptor.namespace + "/" + kind + "/" + contribution.name))
        ]))
    }
    let dependencies = ArrayList<JsonNode>()
    for (dependency in descriptor.componentDependencies) {
        dependencies.add(jsonObject([
            JsonObjectEntry("namespace", jsonString(dependency.namespace)),
            JsonObjectEntry("version_range", jsonString(dependency.versionRange)),
            JsonObjectEntry("kind", jsonString(pluginContributionKindName(dependency.kind))),
            JsonObjectEntry("name", jsonString(dependency.name))
        ]))
    }
    jsonObject([
        JsonObjectEntry("id", jsonString(descriptor.id)),
        JsonObjectEntry("namespace", jsonString(descriptor.namespace)),
        JsonObjectEntry("version", jsonString(descriptor.version)),
        JsonObjectEntry("entry_kind", jsonString(pluginEntryKindName(descriptor.entryKind))),
        JsonObjectEntry("entrypoint", jsonString(descriptor.entrypoint)),
        JsonObjectEntry("compatibility_profile", jsonString(descriptor.compatibilityProfile)),
        JsonObjectEntry("host_sdk_version", jsonString(AGENT_SDK_VERSION)),
        JsonObjectEntry("sdk_range", jsonString(descriptor.sdkRange)),
        JsonObjectEntry("protocol_range", jsonString(descriptor.protocolRange)),
        JsonObjectEntry("requested_capabilities", jsonArray(descriptor.requestedCapabilities.map({ item => jsonString(item) }))),
        JsonObjectEntry("contributions", jsonArray(contributions.toArray())),
        JsonObjectEntry("component_dependencies", jsonArray(dependencies.toArray())),
        JsonObjectEntry("signature_declared", jsonBool(descriptor.signature != ""))
    ])
}

func pluginPackageNamespace(ecosystem: PluginEcosystem, id: String): String {
    let family = match (ecosystem) {
        case PluginEcosystem.Pi => "pi"
        case PluginEcosystem.Codex => "codex"
        case PluginEcosystem.Axyndra => "axyndra"
    }
    family + ":" + id.trimAscii()
}

func pluginDefaultCompatibilityProfile(family: PluginManifestFamily): String {
    match (family) {
        case PluginManifestFamily.Pi => "pi-package-v1"
        case PluginManifestFamily.Codex => "codex-plugin-v1"
        case PluginManifestFamily.Axyndra => "axyndra-plugin-v1"
    }
}

func pluginComponentKindName(kind: PluginComponentKind): String {
    match (kind) {
        case PluginComponentKind.Skill => "skill"
        case PluginComponentKind.Mcp => "mcp"
        case PluginComponentKind.Prompt => "prompt"
        case PluginComponentKind.Extension => "extension"
        case PluginComponentKind.Hook => "hook"
        case PluginComponentKind.Command => "command"
        case PluginComponentKind.Theme => "theme"
        case PluginComponentKind.HostedOnly => "hosted"
    }
}

func pluginNamespaceComponents(
    namespace: String,
    components: Array<PluginComponent>
): Array<PluginComponent> {
    let normalized = ArrayList<PluginComponent>()
    for (component in components) {
        normalized.add(PluginComponent(
            component.kind,
            component.relativePath,
            status: component.status,
            name: component.name,
            identity: namespace + "/" + pluginComponentKindName(component.kind) + "/" + component.relativePath,
            dependencies: component.dependencies
        ))
    }
    normalized.toArray()
}


// Allocation observation only; cannot authorize a package or bypass any
// digest/manifest validation. Registry supplies its actual shared owner.
public interface PluginPackageMetadataAccounting {
    func beforeDocument(source: String): Unit
    func beforeTreePath(bytes: Int64): Unit
}

func pluginInspectJson(document: String, accounting: ?PluginPackageMetadataAccounting): JsonNode {
    match (accounting) { case Some(value) => value.beforeDocument(document); case None => () }
    parseUnifiedJson(document, maxBytes: 1048576, maxDepth: 32)
}

// The accounted path prepays a fixed 4 MiB scratch before reaching this
// reader. Do not let a replaced/grown manifest allocate an unbounded array.
// Existing callers without accounting retain their original read path.
func pluginReadBoundedInspectionManifest(path: Path): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        let bytes = ArrayList<Byte>()
        let buffer = Array<Byte>(65536, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            if (count > 1048576 - bytes.size) {
                // Preserve the existing precise manifest-too-large branch.
                return Array<Byte>(1048577, repeat: 0)
            }
            bytes.add(all: buffer[..count])
        }
        bytes.toArray()
    } finally { file.close() }
}

public func parsePluginPackageManifest(
    family: PluginManifestFamily,
    document: String,
    source!: String = "embedded",
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginPackageResult<PluginPackageDescriptor> {
    match (metadataAccounting) {
        case Some(actual78) => match (actual78 as PluginPackagePrivateDocumentAccounting78) {
            case Some(private78) => return pluginParsePrivateManifest78(family, document, source, private78)
            case None => ()
        }
        case None => ()
    }
    let value = try {
        pluginInspectJson(document, metadataAccounting)
    } catch (error: JsonException) {
        return pluginPackageError("plugin.manifest_parse", error.message, source: source)
    }
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return pluginPackageError(
            "plugin.manifest_object_required",
            "plugin manifest root must be an object",
            source: source
        )
    }
    match (family) {
        case PluginManifestFamily.Pi => parsePiPackage(value, source)
        case PluginManifestFamily.Codex => parseCodexPackage(value, source)
        case PluginManifestFamily.Axyndra => parseAxyndraPackage(value, source)
    }
}

public func inspectPluginPackage(root: String,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None): PluginPackageResult<PluginPackageDescriptor> {
    let authored = Path(root).normalize()
    if (!exists(authored)) {
        return pluginPackageError("plugin.root_missing", "plugin package root does not exist", source: root)
    }
    let info = try {
        FileInfo(authored)
    } catch (error: Exception) {
        return pluginPackageError("plugin.root_unreadable", error.message, source: root)
    }
    if (!info.isDirectory() || info.isSymbolicLink()) {
        return pluginPackageError(
            "plugin.root_invalid",
            "plugin package root must be a non-symlink directory",
            source: root
        )
    }
    let canonical = try {
        canonicalize(authored).toString()
    } catch (_: Exception) {
        authored.toString()
    }
    let digest = match (pluginContentDigest(canonical, metadataAccounting: metadataAccounting)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let rootPluginPath = Path(canonical).join("plugin.json")
    let hasRootPlugin = exists(rootPluginPath)
    var useRootCodex = false
    if (hasRootPlugin) {
        let rootManifest = match (pluginReadManifest(canonical, "plugin.json", metadataAccounting: metadataAccounting)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        let rootValue = try {
            pluginInspectJson(rootManifest, metadataAccounting)
        } catch (error: JsonException) {
            return pluginPackageError("plugin.manifest_parse", error.message, source: canonical, field: "plugin.json")
        }
        let schema = match (pluginOptionalText(rootValue, "$schema", "")) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        if (schema.startsWith("https://agent-plugins.org/schemas/")) {
            if (schema != "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json") {
                return pluginPackageError(
                    "plugin.schema_unsupported",
                    "Codex root manifest declares an unsupported schema",
                    source: canonical,
                    field: "$schema"
                )
            }
            useRootCodex = true
        }
    }
    let hasLegacyCodex = exists(Path(canonical).join(".codex-plugin/plugin.json"))
    let hasCodexManifest = useRootCodex || hasLegacyCodex
    let hasPiDeclaration = pluginHasPiDeclaration(canonical, metadataAccounting: metadataAccounting)
    let hasPiPackage = hasPiDeclaration || (
        exists(Path(canonical).join("package.json")) &&
            pluginHasPiConventionalResources(canonical)
    )
    if (exists(Path(canonical).join("axyndra.plugin.json")) &&
        (hasCodexManifest || hasPiPackage)) {
        return pluginPackageError(
            "plugin.manifest_conflict",
            "package contains manifests from more than one plugin ecosystem",
            source: canonical
        )
    }
    if (hasCodexManifest && hasPiPackage) {
        return pluginPackageError(
            "plugin.manifest_conflict",
            "package declares both Pi and Codex plugin identities",
            source: canonical
        )
    }
    let candidates = [
        ("axyndra.plugin.json", PluginManifestFamily.Axyndra),
        ("plugin.json", PluginManifestFamily.Codex),
        (".codex-plugin/plugin.json", PluginManifestFamily.Codex),
        ("package.json", PluginManifestFamily.Pi),
        ("mcp.json", PluginManifestFamily.Codex),
        (".mcp.json", PluginManifestFamily.Codex)
    ]
    for (candidate in candidates) {
        let path = Path(canonical).join(candidate[0])
        if (!exists(path)) { continue }
        if (candidate[0] == "plugin.json" && !useRootCodex) { continue }
        if (candidate[0] == "package.json" && !hasPiPackage) { continue }
        if (candidate[0] == ".codex-plugin/plugin.json") {
            let directory = Path(canonical).join(".codex-plugin")
            let directoryInfo = try { FileInfo(directory) } catch (error: Exception) {
                return pluginPackageError("plugin.manifest_unreadable", error.message, source: canonical)
            }
            if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink()) {
                return pluginPackageError("plugin.manifest_invalid", "Codex compatibility manifest directory must be a non-symlink directory", source: canonical)
            }
        }
        let manifest = match (pluginReadManifest(canonical, candidate[0], metadataAccounting: metadataAccounting)) {
            case PluginPackageResult.Ok(document) => document
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        match (parsePluginPackageManifest(candidate[1], manifest, source: "local:" + canonical, metadataAccounting: metadataAccounting)) {
            case PluginPackageResult.Ok(value) =>
                var components = if (value.ecosystem == PluginEcosystem.Pi) {
                    pluginPiConventionalComponents(canonical, value.components, manifest, metadataAccounting: metadataAccounting)
                } else if (candidate[0] == "mcp.json" || candidate[0] == ".mcp.json") {
                    [PluginComponent(PluginComponentKind.Mcp, candidate[0], status: PluginComponentStatus.Blocked)]
                } else {
                    value.components
                }
                var overlayPath = if (candidate[0] == ".codex-plugin/plugin.json") {
                    candidate[0]
                } else {
                    ""
                }
                var hookDeclarations = value.hookDeclarations
                if (candidate[0] == "plugin.json") {
                    match (pluginCodexPortableComponents(canonical, manifest, components, metadataAccounting: metadataAccounting)) {
                        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                        case PluginPackageResult.Ok(layout) =>
                            components = layout.components
                            overlayPath = layout.overlayPath
                            hookDeclarations = layout.hookDeclarations
                    }
                }
                if (candidate[0] == ".codex-plugin/plugin.json") {
                    match (pluginCodexPortableComponents(canonical, manifest, components, metadataAccounting: metadataAccounting)) {
                        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                        case PluginPackageResult.Ok(layout) =>
                            components = layout.components
                            overlayPath = layout.overlayPath
                            hookDeclarations = layout.hookDeclarations
                    }
                }
                let profile = if (candidate[0] == "plugin.json") {
                    "codex-portable-v1"
                } else if (candidate[0] == ".codex-plugin/plugin.json") {
                    "codex-compat-v1"
                } else if (candidate[0] == "mcp.json") {
                    "codex-portable-mcp-v1"
                } else if (candidate[0] == ".mcp.json") {
                    "codex-compat-mcp-v1"
                } else {
                    value.compatibilityProfile
                }
                return PluginPackageResult.Ok(PluginPackageDescriptor(
                    value.id,
                    value.version,
                    value.ecosystem,
                    value.family,
                    value.source,
                    root: canonical,
                    manifestPath: candidate[0],
                    overlayPath: overlayPath,
                    compatibilityProfile: profile,
                    components: components,
                    hookDeclarations: hookDeclarations,
                    dependencies: value.dependencies,
                    componentDependencies: value.componentDependencies,
                    missingDependencies: pluginMissingDependencies(canonical, value.dependencies),
                    entrypoint: value.entrypoint,
                    entryKind: value.entryKind,
                    contributions: value.contributions,
                    requestedCapabilities: value.requestedCapabilities,
                    sdkRange: value.sdkRange,
                    protocolRange: value.protocolRange,
                    contentDigest: digest,
                    declaredContentDigest: value.declaredContentDigest,
                    signature: value.signature
                ))
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
    }
    if (exists(Path(canonical).join("SKILL.md"))) {
        let pieces = canonical.split("/")
        let id = if (pieces.isEmpty()) { "skill" } else { pieces[pieces.size - 1] }
        return PluginPackageResult.Ok(PluginPackageDescriptor(
            id,
            "0.0.0",
            PluginEcosystem.Pi,
            PluginManifestFamily.Pi,
            "local:" + canonical,
            root: canonical,
            manifestPath: "SKILL.md",
            compatibilityProfile: "pi-skill-file-v1",
            contentDigest: digest,
            components: [PluginComponent(PluginComponentKind.Skill, "SKILL.md", name: id)]
        ))
    }
    pluginPackageError(
        "plugin.manifest_missing",
        "plugin package has no supported manifest",
        source: canonical
    )
}
func pluginReadManifest(root: String, relativePath: String,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None): PluginPackageResult<String> {
    let path = Path(root).join(relativePath)
    let info = try {
        FileInfo(path)
    } catch (error: Exception) {
        return pluginPackageError("plugin.manifest_unreadable", error.message, source: root)
    }
    if (!info.isRegular() || info.isSymbolicLink()) {
        return pluginPackageError(
            "plugin.manifest_invalid",
            "plugin manifest must be a regular non-symlink file",
            source: root,
            field: relativePath
        )
    }
    try {
        let bytes = match (metadataAccounting) {
            case Some(_) => pluginReadBoundedInspectionManifest(path)
            case None => File.readFrom(path)
        }
        if (bytes.size > 1048576) {
            return pluginPackageError(
                "plugin.manifest_too_large",
                "plugin manifest exceeds the 1 MiB limit",
                source: root,
                field: relativePath
            )
        }
        PluginPackageResult.Ok(String.fromUtf8(bytes))
    } catch (error: Exception) {
        pluginPackageError("plugin.manifest_unreadable", error.message, source: root, field: relativePath)
    }
}

func pluginHasPiDeclaration(root: String,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None): Bool {
    match (metadataAccounting) {
        case Some(actual78) => match (actual78 as PluginPackagePrivateDocumentAccounting78) {
            case Some(private78) => return pluginHasPrivatePiDeclaration78(root, private78)
            case None => ()
        }
        case None => ()
    }
    match (pluginReadManifest(root, "package.json", metadataAccounting: metadataAccounting)) {
        case PluginPackageResult.Err(_) => false
        case PluginPackageResult.Ok(document) =>
            let value = try { pluginInspectJson(document, metadataAccounting) } catch (_: Exception) {
                return false
            }
            value.field("pi").isSome()
    }
}

func pluginHasPiConventionalResources(root: String): Bool {
    for (relativePath in ["extensions", "skills", "prompts", "themes"]) {
        let path = Path(root).join(relativePath)
        if (!exists(path)) { continue }
        let info = try { FileInfo(path) } catch (_: Exception) { continue }
        if (info.isDirectory() && !info.isSymbolicLink()) { return true }
    }
    false
}

func pluginMissingDependencies(
    root: String,
    dependencies: Array<PluginPackageDependency>
): Array<String> {
    let missing = ArrayList<String>()
    for (dependency in dependencies) {
        if (dependency.optional || dependency.development) { continue }
        if (!exists(Path(root).join("node_modules").join(dependency.name))) {
            missing.add(dependency.name)
        }
    }
    missing.toArray()
}

func pluginCodexPortableComponents(
    root: String,
    manifestDocument: String,
    declared: Array<PluginComponent>,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginPackageResult<PluginCodexLayout> {
    let manifest = try {
        pluginInspectJson(manifestDocument, metadataAccounting)
    } catch (error: JsonException) {
        return pluginPackageError("plugin.manifest_parse", error.message, source: root)
    }
    var overlay = pluginCodexOpenAiOverlay(manifest)
    var overlayPath = if (overlay.isSome()) { "plugin.json#extensions.com.openai" } else { "" }
    if (overlay.isNone() && exists(Path(root).join(".codex-plugin/plugin.json"))) {
        let fallbackDocument = match (pluginReadManifest(root, ".codex-plugin/plugin.json", metadataAccounting: metadataAccounting)) {
            case PluginPackageResult.Ok(text) => text
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        match (parsePluginPackageManifest(
            PluginManifestFamily.Codex, fallbackDocument, source: "local:" + root, metadataAccounting: metadataAccounting
        )) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(_) => ()
        }
        let fallback = try {
            pluginInspectJson(fallbackDocument, metadataAccounting)
        } catch (error: JsonException) {
            return pluginPackageError("plugin.manifest_parse", error.message, source: root)
        }
        overlay = match (pluginCodexOpenAiOverlay(fallback)) {
            case Some(value) => Some(value)
            case None => Some(fallback)
        }
        overlayPath = ".codex-plugin/plugin.json"
    }
    let components = ArrayList<PluginComponent>()
    for (component in declared where component.kind != PluginComponentKind.Hook) {
        components.add(component)
    }
    let hookDeclarations = ArrayList<PluginHookDeclaration>()
    let skillsPath = Path(root).join("skills")
    if (exists(skillsPath)) {
        let info = try { FileInfo(skillsPath) } catch (error: Exception) {
            return pluginPackageError("plugin.component_unreadable", error.message, source: root, field: "skills")
        }
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return pluginPackageError(
                "plugin.component_invalid",
                "portable Codex skills must be a non-symlink directory",
                source: root,
                field: "skills"
            )
        }
        if (!pluginHasComponentPath(components, PluginComponentKind.Skill, "skills")) {
            components.add(PluginComponent(PluginComponentKind.Skill, "skills"))
        }
    }
    let mcpPath = Path(root).join("mcp.json")
    if (exists(mcpPath)) {
        let info = try { FileInfo(mcpPath) } catch (error: Exception) {
            return pluginPackageError("plugin.component_unreadable", error.message, source: root, field: "mcp.json")
        }
        if (!info.isRegular() || info.isSymbolicLink()) {
            return pluginPackageError(
                "plugin.component_invalid",
                "portable Codex mcp.json must be a non-symlink file",
                source: root,
                field: "mcp.json"
            )
        }
        if (!pluginHasComponentPath(components, PluginComponentKind.Mcp, "mcp.json")) {
            components.add(PluginComponent(PluginComponentKind.Mcp, "mcp.json", status: PluginComponentStatus.Blocked))
        }
    }
    match (overlay) {
        case Some(value) =>
            for ((field, kind) in [
                ("apps", PluginComponentKind.HostedOnly),
                ("app", PluginComponentKind.HostedOnly),
                ("commands", PluginComponentKind.Command)
            ]) {
                match (appendPathComponents(
                    value, field, kind, components, root,
                    status: PluginComponentStatus.Blocked
                )) {
                    case PluginPackageResult.Ok(_) => ()
                    case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                }
            }
        case None => ()
    }
    let hookConfig = match (overlay) {
        case Some(value) => match (value.field("hooks")) {
            case Some(item) => Some(item)
            case None => manifest.field("hooks")
        }
        case None => manifest.field("hooks")
    }
    match (hookConfig) {
        case Some(value) => match (pluginCodexHookConfiguration(
            root, value, "plugin.json#hooks", components, metadataAccounting: metadataAccounting
        )) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(items) => hookDeclarations.add(all: items)
        }
        case None =>
            let defaultHooks = Path(root).join("hooks/hooks.json")
            if (exists(defaultHooks)) {
                let document = match (pluginReadManifest(root, "hooks/hooks.json", metadataAccounting: metadataAccounting)) {
                    case PluginPackageResult.Ok(text) => text
                    case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                }
                let parsed = try {
                    pluginInspectJson(document, metadataAccounting)
                } catch (error: JsonException) {
                    return pluginPackageError(
                        "plugin.hook_config_parse", error.message,
                        source: root, field: "hooks/hooks.json"
                    )
                }
                match (pluginCodexHookEvents(parsed, "hooks/hooks.json")) {
                    case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                    case PluginPackageResult.Ok(items) => hookDeclarations.add(all: items)
                }
                components.add(PluginComponent(
                    PluginComponentKind.Hook,
                    "hooks/hooks.json",
                    status: if (hookDeclarations.isEmpty()) {
                        PluginComponentStatus.Blocked
                    } else {
                        PluginComponentStatus.Supported
                    }
                ))
                if (overlayPath == "") { overlayPath = "hooks/hooks.json" }
            }
    }
    PluginPackageResult.Ok(PluginCodexLayout(
        components.toArray(), overlayPath,
        hookDeclarations: hookDeclarations.toArray()
    ))
}

func pluginCodexOpenAiOverlay(value: JsonNode): ?JsonNode {
    match (value.field("extensions")) {
        case Some(extensions) => match (extensions.field("com.openai")) {
            case Some(overlay) => Some(overlay)
            case None => None
        }
        case None => None
    }
}
func pluginCodexHookConfiguration(
    root: String,
    value: JsonNode,
    source: String,
    components: ArrayList<PluginComponent>,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginPackageResult<Array<PluginHookDeclaration>> {
    let output = ArrayList<PluginHookDeclaration>()
    if (value.unifiedKind == UnifiedJsonKind.Object) {
        match (pluginCodexHookEvents(value, source)) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(items) => output.add(all: items)
        }
        components.add(PluginComponent(
            PluginComponentKind.Hook, "hooks",
            status: if (output.isEmpty()) {
                PluginComponentStatus.Blocked
            } else {
                PluginComponentStatus.Supported
            }
        ))
    } else {
        let paths = match (pluginPathValues(value, "hooks", source)) {
            case PluginPackageResult.Ok(items) => items
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        for (path in paths) {
            let document = match (pluginReadManifest(root, path, metadataAccounting: metadataAccounting)) {
                case PluginPackageResult.Ok(text) => text
                case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            }
            let parsed = try {
                pluginInspectJson(document, metadataAccounting)
            } catch (error: JsonException) {
                return pluginPackageError(
                    "plugin.hook_config_parse", error.message, source: root, field: path
                )
            }
            let items = match (pluginCodexHookEvents(parsed, path)) {
                case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
                case PluginPackageResult.Ok(value) => value
            }
            output.add(all: items)
            components.add(PluginComponent(
                PluginComponentKind.Hook,
                path,
                status: if (items.isEmpty()) {
                    PluginComponentStatus.Blocked
                } else {
                    PluginComponentStatus.Supported
                }
            ))
        }
    }
    var preCount: Int64 = 0
    var postCount: Int64 = 0
    for (handler in output) {
        if (handler.event == "PreToolUse") { preCount += 1 }
        if (handler.event == "PostToolUse") { postCount += 1 }
    }
    if (preCount > 32 || postCount > 32) {
        return pluginPackageError(
            "plugin.hook_handler_limit",
            "Codex hook event exceeds the 32-handler package limit",
            source: source,
            field: "hooks"
        )
    }
    PluginPackageResult.Ok(output.toArray())
}

func pluginCodexHookEvents(
    value: JsonNode,
    source: String
): PluginPackageResult<Array<PluginHookDeclaration>> {
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return pluginPackageError(
            "plugin.hook_config_invalid", "Codex hooks must be an object", source: source
        )
    }
    let events = match (value.field("hooks")) {
        case Some(item) =>
            if (item.unifiedKind != UnifiedJsonKind.Object) {
                return pluginPackageError(
                    "plugin.hook_events_invalid", "Codex hooks field must be an object",
                    source: source, field: "hooks"
                )
            }
            item
        case None => value
    }
    let output = ArrayList<PluginHookDeclaration>()
    for (eventEntry in events.fields) {
        let event = eventEntry.name
        if (event != "PreToolUse" && event != "PostToolUse") { continue }
        if (eventEntry.value.unifiedKind != UnifiedJsonKind.List) {
            return pluginPackageError(
                "plugin.hook_handlers_invalid", "Codex hook event handlers must be an array",
                source: source, field: event
            )
        }
        for (group in eventEntry.value.items) {
            if (group.unifiedKind != UnifiedJsonKind.Object) {
                return pluginPackageError(
                    "plugin.hook_group_invalid", "Codex hook handler group must be an object",
                    source: source, field: event
                )
            }
            let matcher = match (group.field("matcher")) {
                case Some(item) =>
                    if (item.unifiedKind != UnifiedJsonKind.Text ||
                        !pluginCodexHookMatcherSupported(item.text)) {
                        return pluginPackageError(
                            "plugin.hook_matcher_unsupported",
                            "Codex hook matcher must be '*' or one exact tool name",
                            source: source, field: event + ".matcher"
                        )
                    }
                    item.text.trimAscii()
                case None => "*"
            }
            let actions = match (group.field("hooks")) {
                case Some(item) => item
                case None => return pluginPackageError(
                    "plugin.hook_actions_missing", "Codex hook group must declare hooks",
                    source: source, field: event
                )
            }
            if (actions.unifiedKind != UnifiedJsonKind.List) {
                return pluginPackageError(
                    "plugin.hook_actions_invalid", "Codex hook actions must be an array",
                    source: source, field: event
                )
            }
            for (action in actions.items) {
                if (action.unifiedKind != UnifiedJsonKind.Object) {
                    return pluginPackageError(
                        "plugin.hook_action_invalid", "Codex hook action must be an object",
                        source: source, field: event
                    )
                }
                let kind = match (action.field("type")) {
                    case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
                    case None => ""
                }
                if (kind != "command") {
                    return pluginPackageError(
                        "plugin.hook_action_unsupported", "only Codex command hooks are supported",
                        source: source, field: event + ".type"
                    )
                }
                let command = match (action.field("command")) {
                    case Some(item) =>
                        if (item.unifiedKind != UnifiedJsonKind.Text || item.text.trimAscii() == "" ||
                            item.text.size > 8192 || item.text.contains("\u{0000}")) {
                            return pluginPackageError(
                                "plugin.hook_command_invalid", "Codex hook command is invalid",
                                source: source, field: event + ".command"
                            )
                        }
                        item.text
                    case None => return pluginPackageError(
                        "plugin.hook_command_missing", "Codex command hook must declare command",
                        source: source, field: event
                    )
                }
                var timeoutMillis: Int64 = 2000
                match (action.field("timeout")) {
                    case Some(item) =>
                        if (item.unifiedKind != UnifiedJsonKind.Number) {
                            return pluginPackageError(
                                "plugin.hook_timeout_invalid", "Codex hook timeout must be integer seconds",
                                source: source, field: event + ".timeout"
                            )
                        }
                        let seconds = try { Int64.parse(item.asNumberText()) } catch (_: Exception) { -1 }
                        if (seconds < 1 || seconds > 30) {
                            return pluginPackageError(
                                "plugin.hook_timeout_invalid", "Codex hook timeout must be between 1 and 30 seconds",
                                source: source, field: event + ".timeout"
                            )
                        }
                        timeoutMillis = seconds * 1000
                    case None => ()
                }
                output.add(PluginHookDeclaration(event, matcher, command, timeoutMillis))
                var eventCount: Int64 = 0
                for (existing in output where existing.event == event) { eventCount += 1 }
                if (eventCount > 32) {
                    return pluginPackageError(
                        "plugin.hook_handler_limit", "Codex hook event exceeds the 32-handler package limit",
                        source: source, field: event
                    )
                }
            }
        }
    }
    PluginPackageResult.Ok(output.toArray())
}

func pluginCodexHookMatcherSupported(value: String): Bool {
    let matcher = value.trimAscii()
    if (matcher == "*") { return true }
    if (matcher == "" || matcher.contains("*") || matcher.contains(" ") || matcher.contains("\t")) {
        return false
    }
    for (pattern in ["|", "^", "$", "(", ")", "[", "]", "{", "}", "+", "?", "\\"]) {
        if (matcher.contains(pattern)) { return false }
    }
    true
}
func pluginHasComponentPath(
    components: ArrayList<PluginComponent>,
    kind: PluginComponentKind,
    path: String
): Bool {
    for (component in components) {
        if (component.kind == kind && component.relativePath == path) { return true }
    }
    false
}

class PluginTreeDigestState {
    let paths: ArrayList<String> = ArrayList<String>()
    var fileCount: Int64 = 0
    var totalBytes: Int64 = 0
    var error: ?PluginPackageError = None
}

func pluginCollectTreePaths(
    directory: Path,
    relativeDirectory: String,
    state: PluginTreeDigestState,
    depth: Int64,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): Unit {
    if (depth > 64 || state.error.isSome()) {
        state.error = Some(PluginPackageError(
            "plugin.package_tree_limit",
            "package tree exceeds the directory depth limit"
        ))
        return
    }
    Directory.walk(directory, { info: FileInfo =>
        match (metadataAccounting) {
            case Some(value) => value.beforeTreePath(relativeDirectory.size + info.name.size + 1)
            case None => ()
        }
        let relativePath = if (relativeDirectory == "") {
            info.name
        } else {
            relativeDirectory + "/" + info.name
        }
        if (relativePath == ".git" || relativePath == ".hg" || relativePath == ".svn") {
            true
        } else if (info.isSymbolicLink()) {
            state.error = Some(PluginPackageError(
                "plugin.package_symlink_unsupported",
                "package content digests do not follow symbolic links",
                field: relativePath
            ))
            false
        } else if (info.isDirectory()) {
            pluginCollectTreePaths(info.path, relativePath, state, depth + 1, metadataAccounting: metadataAccounting)
            state.error.isNone()
        } else if (info.isRegular()) {
            if (state.fileCount >= 10000 || state.totalBytes + info.size > 268435456) {
                state.error = Some(PluginPackageError(
                    "plugin.package_tree_limit",
                    "package tree exceeds the file count or 256 MiB digest limit",
                    field: relativePath
                ))
                false
            } else {
                state.fileCount += 1
                state.totalBytes += info.size
                state.paths.add(relativePath)
                true
            }
        } else {
            state.error = Some(PluginPackageError(
                "plugin.package_entry_unsupported",
                "package contains an entry that is not a regular file or directory",
                field: relativePath
            ))
            false
        }
    })
}

func pluginContentDigest(root: String,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None): PluginPackageResult<String> {
    let state = PluginTreeDigestState()
    try {
        pluginCollectTreePaths(Path(root), "", state, 0, metadataAccounting: metadataAccounting)
    } catch (error: Exception) {
        return pluginPackageError("plugin.package_tree_unreadable", error.message, source: root)
    }
    match (state.error) {
        case Some(error) => return PluginPackageResult.Err(error)
        case None => ()
    }
    sort(state.paths)
    let payload = StringBuilder()
    payload.append("axyndra-package-tree-v2\n")
    var verifiedBytes: Int64 = 0
    for (relativePath in state.paths) {
        let path = Path(root).join(relativePath)
        let info = try { FileInfo(path) } catch (error: Exception) {
            return pluginPackageError("plugin.package_tree_unreadable", error.message, source: root, field: relativePath)
        }
        if (!info.isRegular() || info.isSymbolicLink()) {
            return pluginPackageError(
                "plugin.package_tree_changed",
                "package file changed while its content digest was being computed",
                source: root,
                field: relativePath
            )
        }
        if (info.size < 0 || info.size > 268435456 - verifiedBytes) {
            return pluginPackageError("plugin.package_tree_limit", "package contents exceed the 256 MiB digest limit", source: root, field: relativePath)
        }
        verifiedBytes += info.size
        // Preserve the exact v2 tree format, but do not allocate each native
        // library or run the small canonical-value SHA implementation over it.
        let fileDigest = try { pluginPackageFileDigest(path, info.size, root) } catch (_: Exception) {
            return pluginPackageError("plugin.package_tree_changed",
                "package file changed or could not be read within its recorded size", source: root, field: relativePath)
        }
        let after = try { FileInfo(path) } catch (_: Exception) {
            return pluginPackageError("plugin.package_tree_changed", "package file disappeared during verification", source: root, field: relativePath)
        }
        if (!after.isRegular() || after.isSymbolicLink() || after.size != info.size || after.canExecute() != info.canExecute()) {
            return pluginPackageError("plugin.package_tree_changed", "package file metadata changed during verification", source: root, field: relativePath)
        }
        payload.append(relativePath.size.toString())
        payload.append(":")
        payload.append(relativePath)
        payload.append(":")
        payload.append(info.canExecute().toString())
        payload.append(":")
        payload.append(info.size.toString())
        payload.append(":")
        payload.append(fileDigest)
        payload.append("\n")
    }
    PluginPackageResult.Ok("sha256:" + modelPolicySha256Text(payload.toString()))
}

// The caller supplies the size from its bounded file inspection. Contents are
// still re-read on every inspection; this is neither a cache nor an mtime trust
// shortcut. The canonical tree digest and installed lock format stay v2.
func pluginPackageFileDigest(path: Path, expectedSize: Int64, root: String): String {
    if (expectedSize < 0 || expectedSize > 268435456) {
        throw IllegalArgumentException("package file size exceeds digest bounds")
    }
    pluginPackageDigestPath(path, root)
    let file = File(path, OpenMode.Read)
    let hash = SHA256()
    var count: Int64 = 0
    try {
        let buffer = Array<Byte>(65536, repeat: 0)
        while (true) {
            let read = file.read(buffer)
            if (read == 0) { break }
            if (read > expectedSize - count) { throw IllegalArgumentException("package file grew during verification") }
            hash.write(buffer[..read]); count += read
        }
    } finally { file.close() }
    pluginPackageDigestPath(path, root)
    if (count != expectedSize) {
        throw IllegalArgumentException("package file size changed during verification")
    }
    let digits = "0123456789abcdef".toArray()
    let result = ArrayList<Byte>()
    for (byte in hash.finish()) { result.add(digits[Int64(byte / 16u8)]); result.add(digits[Int64(byte % 16u8)]) }
    String.fromUtf8(result.toArray())
}

// Reject symlink traversal even when a directory changed after the tree walk.
// These are path/metadata checks, not an atomic inode snapshot: every caller
// must still compare the resulting digest with its mounted content binding.
func pluginPackageDigestPath(path: Path, root: String): Unit {
    let authored = path.normalize().toString()
    if (root == "/" || canonicalize(Path(root)).toString() != root ||
        FileInfo(root).isSymbolicLink() || !authored.startsWith(root + "/") ||
        canonicalize(path).toString() != authored) {
        throw IllegalArgumentException("package path changed or escaped its root")
    }
    var current = Path(root)
    for (component in authored[root.size + 1..].split("/")) {
        current = current.join(component)
        if (FileInfo(current).isSymbolicLink()) { throw IllegalArgumentException("package path traverses a symbolic link") }
    }
}

func pluginPiConventionalComponents(
    root: String,
    declared: Array<PluginComponent>,
    manifestDocument: String,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): Array<PluginComponent> {
    match (metadataAccounting) {
        case Some(actual78) => match (actual78 as PluginPackagePrivateDocumentAccounting78) {
            case Some(private78) => return pluginPrivatePiConventionalComponents78(root, declared, manifestDocument, private78)
            case None => ()
        }
        case None => ()
    }
    let document = try {
        pluginInspectJson(manifestDocument, metadataAccounting)
    } catch (_: Exception) {
        return declared
    }
    let resources = match (document.field("pi")) {
        case Some(value) => value
        case None => document
    }
    let values = ArrayList<PluginComponent>()
    for (component in declared) { values.add(component) }
    for ((relativePath, kind) in [
        ("skills", PluginComponentKind.Skill),
        ("prompts", PluginComponentKind.Prompt),
        ("extensions", PluginComponentKind.Extension),
        ("themes", PluginComponentKind.Theme),
    ]) {
        if (resources.field(relativePath).isSome()) { continue }
        let path = Path(root).join(relativePath)
        if (!exists(path)) { continue }
        let info = try { FileInfo(path) } catch (_: Exception) { continue }
        if (info.isDirectory() && !info.isSymbolicLink()) {
            let status = if (kind == PluginComponentKind.Theme) {
                PluginComponentStatus.Blocked
            } else {
                PluginComponentStatus.Supported
            }
            values.add(PluginComponent(kind, relativePath, status: status))
        }
    }
    values.toArray()
}

func parsePiPackage(value: JsonNode, source: String): PluginPackageResult<PluginPackageDescriptor> {
    let id = match (pluginRequiredText(value, "name", source)) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let version = match (pluginRequiredText(value, "version", source)) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let hasPiManifest = value.field("pi").isSome()
    let pi = match (value.field("pi")) {
        case Some(item) =>
            if (item.unifiedKind != UnifiedJsonKind.Object) {
                return pluginPackageError(
                    "plugin.pi_object_required",
                    "package.json pi field must be an object",
                    source: source,
                    field: "pi"
                )
            }
            item
        case None => value
    }
    let components = ArrayList<PluginComponent>()
    for ((field, kind) in [
        ("skills", PluginComponentKind.Skill),
        ("prompts", PluginComponentKind.Prompt),
        ("extensions", PluginComponentKind.Extension),
        ("themes", PluginComponentKind.Theme)
    ]) {
        match (pi.field(field)) {
            case Some(item) =>
                if (item.unifiedKind == UnifiedJsonKind.List && item.items.size > 128) {
                    return pluginPackageError(
                        "plugin.component_selector_limit",
                        "Pi resource selector arrays are limited to 128 entries",
                        source: source,
                        field: field
                    )
                }
                if (item.unifiedKind == UnifiedJsonKind.Text && item.text.size > 256) {
                    return pluginPackageError(
                        "plugin.component_selector_limit",
                        "Pi resource selectors are limited to 256 characters",
                        source: source,
                        field: field
                    )
                }
            case None => ()
        }
        let status = if (kind == PluginComponentKind.Theme) {
            PluginComponentStatus.Blocked
        } else {
            PluginComponentStatus.Supported
        }
        match (appendPathComponents(pi, field, kind, components, source, status: status)) {
            case PluginPackageResult.Ok(_) => ()
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
        for (component in components where component.kind == kind) {
            if (!pluginPiSelectorValid(component.relativePath)) {
                return pluginPackageError(
                    "plugin.component_selector_invalid",
                    "Pi resource selector is unsafe or uses unsupported glob syntax",
                    source: source,
                    field: field
                )
            }
        }
    }
    for ((field, kind) in [
        ("hooks", PluginComponentKind.Hook),
        ("commands", PluginComponentKind.Command)
    ]) {
        match (appendPathComponents(
            pi, field, kind, components, source, status: PluginComponentStatus.Blocked
        )) {
            case PluginPackageResult.Ok(_) => ()
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
    }
    var extensionCount: Int64 = 0
    var extensionCandidate = ""
    for (component in components where component.kind == PluginComponentKind.Extension) {
        extensionCount += 1
        extensionCandidate = component.relativePath
    }
    let entrypoint = if (extensionCount == 1 &&
        (extensionCandidate.endsWith(".js") || extensionCandidate.endsWith(".mjs") ||
            extensionCandidate.endsWith(".cjs") || extensionCandidate.endsWith(".ts"))) {
        extensionCandidate
    } else {
        ""
    }
    let dependencies = ArrayList<PluginPackageDependency>()
    let requestedCapabilities = ArrayList<String>()
    if (hasPiManifest) {
        match (pi.field("axyndra")) {
            case Some(overlay) =>
                if (overlay.unifiedKind != UnifiedJsonKind.Object) {
                    return pluginPackageError(
                        "plugin.pi_axyndra_invalid",
                        "Pi Axyndra overlay must be an object",
                        source: source,
                        field: "pi.axyndra"
                    )
                }
                match (overlay.field("capabilities")) {
                    case Some(capabilities) =>
                        if (capabilities.unifiedKind != UnifiedJsonKind.List ||
                            capabilities.items.size > 16) {
                            return pluginPackageError(
                                "plugin.capability_list_invalid",
                                "Pi Axyndra capabilities must be a list of at most 16 items",
                                source: source,
                                field: "pi.axyndra.capabilities"
                            )
                        }
                        for (item in capabilities.items) {
                            if (item.unifiedKind != UnifiedJsonKind.Text) {
                                return pluginPackageError(
                                    "plugin.capability_list_invalid",
                                    "Pi Axyndra capabilities must contain strings",
                                    source: source,
                                    field: "pi.axyndra.capabilities"
                                )
                            }
                            let capability = item.text.trimAscii()
                            if (capability != "workspace.read" && capability != "workspace.write") {
                                return pluginPackageError(
                                    "plugin.capability_unsupported",
                                    "Pi JavaScript plugins may request only workspace.read and workspace.write",
                                    source: source,
                                    field: "pi.axyndra.capabilities"
                                )
                            }
                            if (!requestedCapabilities.contains(capability)) {
                                requestedCapabilities.add(capability)
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
    }
    for ((field, optional, development) in [
        ("dependencies", false, false),
        ("optionalDependencies", true, false),
        ("peerDependencies", false, false),
        ("devDependencies", true, true)
    ]) {
        match (pluginParseDependencyMap(value, field, source, optional: optional, development: development)) {
            case PluginPackageResult.Ok(items) =>
                for (item in items) { dependencies.add(item) }
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
    }
    PluginPackageResult.Ok(PluginPackageDescriptor(
        id,
        version,
        PluginEcosystem.Pi,
        PluginManifestFamily.Pi,
        source,
        components: components.toArray(),
        dependencies: dependencies.toArray(),
        compatibilityProfile: if (hasPiManifest) {
            "pi-package-declared-v1"
        } else {
            "pi-package-conventions-v1"
        },
        entrypoint: entrypoint,
        requestedCapabilities: requestedCapabilities.toArray(),
    ))
}

func pluginParseDependencyMap(
    value: JsonNode,
    field: String,
    source: String,
    optional!: Bool = false,
    development!: Bool = false
): PluginPackageResult<Array<PluginPackageDependency>> {
    match (value.field(field)) {
        case None => return PluginPackageResult.Ok([])
        case Some(item) =>
            if (item.unifiedKind != UnifiedJsonKind.Object) {
                return pluginPackageError(
                    "plugin.dependencies_object_required",
                    "package dependency declarations must be an object",
                    source: source,
                    field: field
                )
            }
            let dependencies = ArrayList<PluginPackageDependency>()
            for (entry in item.fields) {
                if (!pluginSafeDependencyName(entry.name) ||
                    entry.value.unifiedKind != UnifiedJsonKind.Text ||
                    entry.value.text.trimAscii() == "") {
                    return pluginPackageError(
                        "plugin.dependency_invalid",
                        "dependency names and version ranges must be valid non-empty strings",
                        source: source,
                        field: field
                    )
                }
                dependencies.add(PluginPackageDependency(
                    entry.name, entry.value.text, optional: optional, development: development
                ))
            }
            PluginPackageResult.Ok(dependencies.toArray())
    }
}

func pluginSafeDependencyName(value: String): Bool {
    let name = value.trimAscii()
    if (name == "" || name.startsWith("/") || name.contains("\\") || name.contains("..")) {
        return false
    }
    let parts = name.split("/")
    if (name.startsWith("@")) {
        return parts.size == 2 && parts[0].size > 1 && parts[1] != ""
    }
    parts.size == 1
}
func parseCodexPackage(value: JsonNode, source: String): PluginPackageResult<PluginPackageDescriptor> {
    let schema = match (pluginOptionalText(value, "$schema", "")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    if (schema != "" && schema != "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json" &&
        schema != "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json") {
        return pluginPackageError(
            "plugin.schema_unsupported",
            "Codex manifest declares an unsupported schema",
            source: source,
            field: "$schema"
        )
    }
    match (value.field("extensions")) {
        case Some(extensions) =>
            if (extensions.unifiedKind != UnifiedJsonKind.Object) {
                return pluginPackageError(
                    "plugin.codex_extensions_invalid",
                    "Codex extensions field must be an object",
                    source: source,
                    field: "extensions"
                )
            }
            match (extensions.field("com.openai")) {
                case Some(overlay) =>
                    if (overlay.unifiedKind != UnifiedJsonKind.Object) {
                        return pluginPackageError(
                            "plugin.codex_overlay_invalid",
                            "OpenAI Codex extension overlay must be an object",
                            source: source,
                            field: "extensions.com.openai"
                        )
                    }
                case None => ()
            }
        case None => ()
    }
    let id = match (pluginOptionalText(value, "name", "codex-plugin")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let version = match (pluginOptionalText(value, "version", "0.0.0")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let components = ArrayList<PluginComponent>()
    for ((field, kind) in [
        ("app", PluginComponentKind.HostedOnly),
        ("apps", PluginComponentKind.HostedOnly),
        ("skills", PluginComponentKind.Skill),
        ("hooks", PluginComponentKind.Hook),
        ("commands", PluginComponentKind.Command)
    ]) {
        let status = if (kind == PluginComponentKind.Hook || kind == PluginComponentKind.Command ||
            kind == PluginComponentKind.HostedOnly) {
            PluginComponentStatus.Blocked
        } else {
            PluginComponentStatus.Supported
        }
        match (appendPathComponents(value, field, kind, components, source, status: status)) {
            case PluginPackageResult.Ok(_) => ()
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        }
    }
    PluginPackageResult.Ok(PluginPackageDescriptor(
        id,
        version,
        PluginEcosystem.Codex,
        PluginManifestFamily.Codex,
        source,
        components: components.toArray(),
        compatibilityProfile: "codex-manifest-v1"
    ))
}

func parseAxyndraPackage(value: JsonNode, source: String): PluginPackageResult<PluginPackageDescriptor> {
    let authoredEntryKind = match (pluginOptionalText(value, "entry_kind", "")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let entryKind = if (authoredEntryKind == "native-executable") {
        PluginEntryKind.NativeExecutable
    } else if (authoredEntryKind == "" || authoredEntryKind == "legacy-process") {
        PluginEntryKind.LegacyProcess
    } else {
        return pluginPackageError("plugin.entry_kind_unsupported",
            "Axyndra executable packages must declare entry_kind native-executable",
            source: source, field: "entry_kind")
    }
    let id = match (pluginRequiredText(value, "id", source)) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let version = match (pluginRequiredText(value, "version", source)) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let authoredEntrypoint = match (pluginRequiredText(value, "entrypoint", source)) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let entrypoint = pluginNormalizeRelativePath(authoredEntrypoint)
    if (entrypoint == "") {
        return pluginPackageError(
            "plugin.entrypoint_escape",
            "plugin entrypoint must remain inside the package",
            source: source,
            field: "entrypoint"
        )
    }
    let capabilities = match (pluginCapabilityList(value, "capabilities", source)) {
        case PluginPackageResult.Ok(items) => items
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    for (capability in capabilities) {
        if (capability == "ambient" || capability == "host.*" || capability == "process.unrestricted") {
            return pluginPackageError(
                "plugin.capability_unsupported",
                "plugin requests an ambient or unrestricted capability",
                source: source,
                field: "capabilities"
            )
        }
    }
    let sdkRange = match (pluginOptionalText(value, "sdk_range", "")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let protocolRange = match (pluginOptionalText(value, "protocol_range", "axyndra-extension-v1")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let contributions = if (entryKind == PluginEntryKind.NativeExecutable) {
        match (validateNativePluginCompatibility(value, sdkRange, protocolRange, capabilities, source)) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(_) => ()
        }
        match (parseNativePluginContributions(value, source)) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(items) => items
        }
    } else { Array<PluginContributionDefinition>() }
    let componentDependencies = match (parsePluginContributionDependencies(value, entryKind, source)) {
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
        case PluginPackageResult.Ok(items) => items
    }
    let contentDigest = match (pluginOptionalText(value, "content_digest", "")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let signature = match (pluginOptionalText(value, "signature", "")) {
        case PluginPackageResult.Ok(text) => text
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    PluginPackageResult.Ok(PluginPackageDescriptor(
        id,
        version,
        PluginEcosystem.Axyndra,
        PluginManifestFamily.Axyndra,
        source,
        compatibilityProfile: if (entryKind == PluginEntryKind.NativeExecutable) {
            "axyndra-native-v2"
        } else { "axyndra-plugin-v1" },
        components: [PluginComponent(PluginComponentKind.Extension, entrypoint, name: id)],
        entrypoint: entrypoint,
        entryKind: entryKind,
        contributions: contributions,
        componentDependencies: componentDependencies,
        requestedCapabilities: capabilities,
        sdkRange: sdkRange,
        protocolRange: protocolRange,
        declaredContentDigest: contentDigest,
        signature: signature
    ))
}

func validateNativePluginCompatibility(
    value: JsonNode,
    sdkRange: String,
    protocolRange: String,
    capabilities: Array<String>,
    source: String
): PluginPackageResult<Unit> {
    if (protocolRange != JAVASCRIPT_EXTENSION_PROTOCOL) {
        return pluginPackageError("plugin.protocol_unsupported",
            "native executable requires protocol_range " + JAVASCRIPT_EXTENSION_PROTOCOL,
            source: source, field: "protocol_range")
    }
    let range = sdkRange.trimAscii()
    if (!range.startsWith("[") || !range.endsWith(")")) {
        return pluginPackageError("plugin.sdk_range_malformed",
            "sdk_range must be a bounded [MAJOR.MINOR.PATCH,MAJOR.MINOR.PATCH) interval",
            source: source, field: "sdk_range")
    }
    let bounds = range[1..range.size - 1].split(",")
    if (bounds.size != 2) {
        return pluginPackageError("plugin.sdk_range_malformed", "sdk_range requires two version bounds",
            source: source, field: "sdk_range")
    }
    let minimum = match (requiredVersion(jsonObject([JsonObjectEntry("min", jsonString(bounds[0].trimAscii()))]), "min", "", source)) {
        case ExtensionRuntimeResult.Ok(version) => version
        case ExtensionRuntimeResult.Err(_) => return pluginPackageError("plugin.sdk_range_malformed",
            "sdk_range minimum must use canonical MAJOR.MINOR.PATCH syntax", source: source, field: "sdk_range")
    }
    let maximum = match (requiredVersion(jsonObject([JsonObjectEntry("max", jsonString(bounds[1].trimAscii()))]), "max", "", source)) {
        case ExtensionRuntimeResult.Ok(version) => version
        case ExtensionRuntimeResult.Err(_) => return pluginPackageError("plugin.sdk_range_malformed",
            "sdk_range maximum must use canonical MAJOR.MINOR.PATCH syntax", source: source, field: "sdk_range")
    }
    if (!minimum.lessThan(maximum)) {
        return pluginPackageError("plugin.sdk_range_malformed", "sdk_range must be nonempty",
            source: source, field: "sdk_range")
    }
    if (!SdkCompatibility(minimum, maximum).includes(parseVersionUnchecked(AGENT_SDK_VERSION))) {
        return pluginPackageError("plugin.sdk_incompatible", "plugin SDK range excludes host SDK " + AGENT_SDK_VERSION,
            source: source, field: "sdk_range")
    }
    match (requiredVersion(value, "version", "", source)) {
        case ExtensionRuntimeResult.Err(_) => return pluginPackageError("plugin.version_malformed",
            "plugin version must use canonical MAJOR.MINOR.PATCH syntax", source: source, field: "version")
        case ExtensionRuntimeResult.Ok(_) => ()
    }
    let seen = ArrayList<String>()
    for (capability in capabilities) {
        if ((capability != "workspace.read" && capability != "workspace.write" && capability != "network.http" && capability != "process.channel" && capability != "process.readview" && capability != "tool.readonly" && capability != "document.store") || seen.contains(capability)) {
            return pluginPackageError("plugin.capability_unsupported",
                "native broker supports unique workspace.read, workspace.write, network.http, process.channel, process.readview, tool.readonly, and document.store requests only",
                source: source, field: "capabilities")
        }
        seen.add(capability)
    }
    PluginPackageResult.Ok(())
}

func parseNativePluginContributions(value: JsonNode, source: String): PluginPackageResult<Array<PluginContributionDefinition>> {
    let declared = match (value.field("contributions")) {
        case Some(items) => items
        case None => return pluginPackageError("plugin.contributions_missing",
            "native executable must declare its typed contributions", source: source, field: "contributions")
    }
    if (declared.unifiedKind != UnifiedJsonKind.List || declared.items.isEmpty() || declared.items.size > 128) {
        return pluginPackageError("plugin.contributions_invalid", "contributions must contain 1 to 128 entries",
            source: source, field: "contributions")
    }
    let output = ArrayList<PluginContributionDefinition>()
    for (original in declared.items) {
        if (nativeInputAttachmentFieldCount(original) > 1) { return pluginPackageError("plugin.contribution_invalid", "duplicate input attachment metadata", source: source, field: "contributions") }
        let attachment = match (original.field("input_attachment")) {
            case Some(value) => match (nativeToolInputAttachmentMetadata(value)) {
                case Some(pair) => pair
                case None => return pluginPackageError("plugin.contribution_invalid", "input attachment metadata has an invalid exact field/limit", source: source, field: "contributions") }
            case None => ("", 0i64)
        }
        let item = if (original.field("input_attachment").isSome()) { nativeContributionWithoutInputAttachment(original) } else { original }
        if (item.unifiedKind != UnifiedJsonKind.Object || (item.fields.size != 2 && item.fields.size != 3)) {
            return pluginPackageError("plugin.contribution_invalid", "contribution requires kind/name and optional kind-specific metadata",
                source: source, field: "contributions")
        }
        let kindText = textField(item, "kind")
        let name = textField(item, "name")
        let kind = if (kindText == "tool") { PluginContributionKind.Tool }
            else if (kindText == "command") { PluginContributionKind.Command }
            else if (kindText == "service") { PluginContributionKind.Service }
            else if (kindText == "model_provider") { PluginContributionKind.ModelProvider }
            else if (kindText == "provider") { PluginContributionKind.Provider }
            else if (kindText == "context_provider") { PluginContributionKind.ContextProvider }
            else if (kindText == "resource_provider") { PluginContributionKind.ResourceProvider }
            else {
                return pluginPackageError("plugin.contribution_unsupported",
                    "native host does not implement contribution kind: " + kindText,
                    source: source, field: "contributions.kind")
            }
        let validName = if (kind == PluginContributionKind.Tool) { validToolName(name) }
            else { validCommandName(name) }
        if (!validName) {
            return pluginPackageError("plugin.contribution_name_invalid", "contribution name is invalid for its kind",
                source: source, field: "contributions.name")
        }
        for (existing in output where existing.kind == kind && existing.name == name) {
            return pluginPackageError("plugin.contribution_duplicate", "duplicate contribution identity: " + kindText + ":" + name,
                source: source, field: "contributions")
        }
        var profile = PluginToolExecutionProfile.Brokered
        var supportsReference = false
        var controls: Array<String> = []
        if (item.fields.size == 3 && item.field("execution_profile").isSome()) {
            let declaredProfile = item.field("execution_profile").getOrThrow()
            if (kind != PluginContributionKind.Tool || declaredProfile.unifiedKind != UnifiedJsonKind.Text ||
                declaredProfile.text != "data_only") {
                return pluginPackageError("plugin.contribution_invalid", "only a Tool may declare the supported data_only execution profile", source: source, field: "contributions") }
            profile = PluginToolExecutionProfile.DataOnly
        } else if (item.fields.size == 3) {
            match (item.field("supports_preparation_reference")) {
                case Some(flag) =>
                    if (kind != PluginContributionKind.Service || flag.unifiedKind != UnifiedJsonKind.Boolean) {
                        return pluginPackageError("plugin.contribution_invalid", "preparation reference support is Service-only boolean metadata", source: source, field: "contributions") }
                    supportsReference = flag.boolValue
                case None =>
                    let declaredControls = match (item.field("allowed_user_controls")) {
                        case Some(value) => value
                        case None => return pluginPackageError("plugin.contribution_invalid", "unknown contribution field", source: source, field: "contributions") }
                    if (kind != PluginContributionKind.Command || declaredControls.unifiedKind != UnifiedJsonKind.List ||
                        declaredControls.items.size != 1 || declaredControls.items[0].unifiedKind != UnifiedJsonKind.Text ||
                        declaredControls.items[0].text != "continuation") {
                        return pluginPackageError("plugin.contribution_invalid", "allowed_user_controls is Command-only and contains exactly continuation", source: source, field: "contributions") }
                    controls = ["continuation"]
            }
        }
        if (attachment[0] != "" && (kind != PluginContributionKind.Tool || profile != PluginToolExecutionProfile.Brokered)) {
            return pluginPackageError("plugin.contribution_invalid", "input attachments belong only to a brokered native Tool", source: source, field: "contributions")
        }
        output.add(PluginContributionDefinition(name, kind, supportsPreparationReference: supportsReference,
            allowedUserControls: controls, executionProfile: profile, inputAttachmentField: attachment[0], inputAttachmentMaxBytes: attachment[1]))
    }
    PluginPackageResult.Ok(output.toArray())
}

func appendPathComponents(
    value: JsonNode,
    field: String,
    kind: PluginComponentKind,
    output: ArrayList<PluginComponent>,
    source: String,
    status!: PluginComponentStatus = PluginComponentStatus.Supported
): PluginPackageResult<Unit> {
    match (value.field(field)) {
        case None => PluginPackageResult.Ok(())
        case Some(item) =>
            if (item.unifiedKind == UnifiedJsonKind.Object) {
                output.add(PluginComponent(kind, field, status: status))
                return PluginPackageResult.Ok(())
            }
            match (pluginPathValues(item, field, source)) {
                case PluginPackageResult.Err(error) => PluginPackageResult.Err(error)
                case PluginPackageResult.Ok(paths) =>
                    for (path in paths) {
                        if (!pluginSafeRelativePath(path)) {
                            return pluginPackageError(
                                "plugin.component_escape",
                                "plugin component path escapes the package",
                                source: source,
                                field: field
                            )
                        }
                        output.add(PluginComponent(kind, path, status: status))
                    }
                    PluginPackageResult.Ok(())
            }
    }
}

func pluginPathValues(
    value: JsonNode,
    field: String,
    source: String
): PluginPackageResult<Array<String>> {
    if (value.unifiedKind == UnifiedJsonKind.Text) {
        let normalized = pluginNormalizeRelativePath(value.text)
        if (normalized == "") {
            return pluginPackageError("plugin.component_path_invalid", "component path must be non-empty and package-relative", source: source, field: field)
        }
        return PluginPackageResult.Ok([normalized])
    }
    if (value.unifiedKind != UnifiedJsonKind.List) {
        return pluginPackageError(
            "plugin.component_paths_invalid",
            "plugin component declaration must be a string or array",
            source: source,
            field: field
        )
    }
    let output = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Text) {
            return pluginPackageError(
                "plugin.component_path_invalid",
                "plugin component paths must be package-relative strings",
                source: source,
                field: field
            )
        }
        let normalized = pluginNormalizeRelativePath(item.text)
        if (normalized == "") {
            return pluginPackageError(
                "plugin.component_path_invalid",
                "plugin component paths must be non-empty and package-relative",
                source: source,
                field: field
            )
        }
        output.add(normalized)
    }
    PluginPackageResult.Ok(output.toArray())
}

func pluginRequiredText(value: JsonNode, field: String, source: String): PluginPackageResult<String> {
    match (value.field(field)) {
        case Some(item) =>
            if (item.unifiedKind == UnifiedJsonKind.Text && item.text.trimAscii() != "") {
                PluginPackageResult.Ok(item.text.trimAscii())
            } else {
                pluginPackageError("plugin.field_invalid", "plugin field must be a non-empty string", source: source, field: field)
            }
        case None => pluginPackageError("plugin.field_missing", "plugin field is required", source: source, field: field)
    }
}

func pluginOptionalText(value: JsonNode, field: String, fallback: String): PluginPackageResult<String> {
    match (value.field(field)) {
        case None => PluginPackageResult.Ok(fallback)
        case Some(item) =>
            if (item.unifiedKind == UnifiedJsonKind.Text && item.text.trimAscii() != "") {
                PluginPackageResult.Ok(item.text.trimAscii())
            } else {
                PluginPackageResult.Err(PluginPackageError("plugin.field_invalid", "plugin field must be a non-empty string", field: field))
            }
    }
}

// Capability resources are opaque policy metadata, not filesystem paths.
// Legacy network.access:host:port values must remain inspectable during
// migration even though native activation rejects that unsupported capability.
func pluginCapabilityList(value: JsonNode, field: String, source: String): PluginPackageResult<Array<String>> {
    let declared = match (value.field(field)) {
        case None => return PluginPackageResult.Ok([])
        case Some(item) => item
    }
    let items = if (declared.unifiedKind == UnifiedJsonKind.Text) {
        [declared]
    } else if (declared.unifiedKind == UnifiedJsonKind.List && declared.items.size <= 128) {
        declared.items
    } else {
        return pluginPackageError("plugin.capability_list_invalid",
            "capabilities must be bounded text or an array of at most 128 strings", source: source, field: field)
    }
    let output = ArrayList<String>()
    for (item in items) {
        if (item.unifiedKind != UnifiedJsonKind.Text || item.text.trimAscii() == "" ||
            item.text.size > 4096 || item.text.contains("\u{0000}")) {
            return pluginPackageError("plugin.capability_list_invalid",
                "capability must be bounded nonempty text", source: source, field: field)
        }
        output.add(item.text.trimAscii())
    }
    PluginPackageResult.Ok(output.toArray())
}

func pluginPackageError<T>(code: String, message: String, source!: String = "", field!: String = ""): PluginPackageResult<T> {
    PluginPackageResult.Err(PluginPackageError(code, message, source: source, field: field))
}

func pluginNormalizeRelativePath(value: String): String {
    let path = value.trimAscii()
    if (path == "" || path.startsWith("/") || path.contains("\\") || path.contains(":") || path.contains("\u{0000}")) {
        return ""
    }
    var normalized = ""
    for (part in path.split("/")) {
        if (part == ".." || part == "") { return "" }
        if (part == ".") { continue }
        normalized = if (normalized == "") { part } else { normalized + "/" + part }
    }
    normalized
}

func pluginSafeRelativePath(value: String): Bool {
    pluginNormalizeRelativePath(value) != ""
}

func pluginPiSelectorValid(value: String): Bool {
    let selector = if (value.startsWith("!")) { value[1..] } else { value }
    if (selector == "" || selector.startsWith("!") || selector.size > 256 ||
        !pluginSafeRelativePath(selector)) { return false }
    for (part in selector.split("/")) {
        if (part.contains("[") || part.contains("]") || part.contains("{") || part.contains("}")) {
            return false
        }
    }
    true
}
