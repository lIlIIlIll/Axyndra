package agent_product

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

public class ProductPluginSourceRequest {
    public let kind: PluginSourceKind
    public let locator: String
    public let version: String
    public let revision: String
    public let registryUrl: String

    public init(
        kind: PluginSourceKind,
        locator: String,
        version!: String = "",
        revision!: String = "",
        registryUrl!: String = "https://registry.npmjs.org/"
    ) {
        this.kind = kind
        this.locator = locator
        this.version = version
        this.revision = revision
        this.registryUrl = registryUrl
    }
}

class ProductPluginSourceEndpoint {
    let host: String
    let port: UInt16
    let isLoopback: Bool

    init(host: String, port: UInt16, isLoopback: Bool) {
        this.host = host
        this.port = port
        this.isLoopback = isLoopback
    }
}

class ProductPluginAcquisitionSpec {
    let kind: PluginSourceKind
    let locator: String
    let packageName: String
    let version: String
    let revision: String
    let registryUrl: String
    let sourceLocator: String
    let networkPolicy: NetworkPolicy
    let workspaceSource: Bool

    init(
        kind: PluginSourceKind,
        locator: String,
        packageName: String,
        version: String,
        revision: String,
        registryUrl: String,
        sourceLocator: String,
        workspaceSource: Bool,
        networkPolicy: NetworkPolicy
    ) {
        this.kind = kind
        this.locator = locator
        this.packageName = packageName
        this.version = version
        this.revision = revision
        this.registryUrl = registryUrl
        this.sourceLocator = sourceLocator
        this.networkPolicy = networkPolicy
        this.workspaceSource = workspaceSource
    }
}

class ProductAcquiredPluginSource {
    let kind: PluginSourceKind
    let locator: String
    let version: String
    let revision: String
    let integrity: String
    let packageRoot: String
    let stageRoot: String

    init(
        kind: PluginSourceKind,
        locator: String,
        version: String,
        revision: String,
        integrity: String,
        packageRoot: String,
        stageRoot: String
    ) {
        this.kind = kind
        this.locator = locator
        this.version = version
        this.revision = revision
        this.integrity = integrity
        this.packageRoot = packageRoot
        this.stageRoot = stageRoot
    }
}

func productPluginSourceSpec(
    request: ProductPluginSourceRequest,
    shellNetworkMode: ShellNetworkMode
): PluginImportResult<ProductPluginAcquisitionSpec> {
    let locator = request.locator.trimAscii()
    if (locator == "" || locator.contains("\n") || locator.contains("\r") || locator.contains("\u{0000}")) {
        return pluginImportError("plugin.source_locator_invalid", "plugin source locator is empty or contains a control character")
    }
    match (request.kind) {
        case PluginSourceKind.Local =>
            return pluginImportError("plugin.source_kind_invalid", "local plugins use the local-path import API")
        case PluginSourceKind.Git =>
            if (request.version != "" || request.revision != request.revision.trimAscii() ||
                !productPluginExactGitRevision(request.revision)) {
                return pluginImportError(
                    "plugin.source_revision_invalid",
                    "Git plugin sources require one exact 40- or 64-character hexadecimal commit"
                )
            }
            let remote = match (productPluginGitEndpoint(locator)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let registryUrl = request.registryUrl.trimAscii()
            let registry = match (productPluginRegistryEndpoint(registryUrl)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let policy = match (productPluginAcquisitionPolicy(
                shellNetworkMode,
                remote,
                registry,
                true
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let canonicalRegistry = productPluginRegistryCanonical(registryUrl)
            PluginImportResult.Ok(ProductPluginAcquisitionSpec(
                PluginSourceKind.Git,
                locator,
                "",
                "",
                request.revision.toAsciiLower(),
                canonicalRegistry,
                locator,
                remote.isNone(),
                policy
            ))
        case PluginSourceKind.Npm =>
            if (request.revision != "" || !productPluginExactVersion(request.version) ||
                !productPluginNpmName(request.locator)) {
                return pluginImportError(
                    "plugin.source_version_invalid",
                    "npm plugin sources require a valid package name and one exact semantic version"
                )
            }
            let registryUrl = request.registryUrl.trimAscii()
            let registry = match (productPluginRegistryEndpoint(registryUrl)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let policy = match (productPluginAcquisitionPolicy(
                shellNetworkMode,
                None,
                registry,
                true
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let canonicalRegistry = productPluginRegistryCanonical(registryUrl)
            PluginImportResult.Ok(ProductPluginAcquisitionSpec(
                PluginSourceKind.Npm,
                request.locator,
                request.locator,
                request.version,
                "",
                canonicalRegistry,
                canonicalRegistry + request.locator,
                false,
                policy
            ))
    }
}

func productPluginExactGitRevision(value: String): Bool {
    if (value.size != 40 && value.size != 64) { return false }
    for (rune in value.toRuneArray()) {
        if (!((rune >= r'0' && rune <= r'9') || (rune >= r'a' && rune <= r'f') ||
            (rune >= r'A' && rune <= r'F'))) {
            return false
        }
    }
    true
}

func productPluginExactVersion(value: String): Bool {
    if (value == "" || value != value.trimAscii() || value.contains(" ") || value.contains("\t") ||
        value.contains("\n") || value.contains("\r")) {
        return false
    }
    let buildParts = value.split("+")
    if (buildParts.size > 2 || buildParts[0] == "") { return false }
    if (buildParts.size == 2 && !productPluginSemverIdentifiers(buildParts[1], false)) { return false }
    let preReleaseParts = buildParts[0].split("-")
    let coreParts = preReleaseParts[0].split(".")
    if (coreParts.size != 3) { return false }
    for (part in coreParts) {
        if (part == "" || (part.size > 1 && part.startsWith("0"))) { return false }
        for (rune in part.toRuneArray()) {
            if (rune < r'0' || rune > r'9') { return false }
        }
    }
    if (preReleaseParts.size > 1) {
        for (index in 1..preReleaseParts.size) {
            if (!productPluginSemverIdentifiers(preReleaseParts[index], true)) { return false }
        }
    }
    true
}

func productPluginSemverIdentifiers(value: String, rejectNumericLeadingZero: Bool): Bool {
    if (value == "") { return false }
    let identifiers = value.split(".")
    for (identifier in identifiers) {
        if (identifier == "") { return false }
        var numeric = true
        for (rune in identifier.toRuneArray()) {
            let digit = rune >= r'0' && rune <= r'9'
            let alpha = (rune >= r'a' && rune <= r'z') || (rune >= r'A' && rune <= r'Z')
            if (!digit && !alpha && rune != r'-') { return false }
            if (!digit) { numeric = false }
        }
        if (rejectNumericLeadingZero && numeric && identifier.size > 1 && identifier.startsWith("0")) {
            return false
        }
    }
    true
}

func productPluginNpmName(value: String): Bool {
    if (value == "" || value.size > 214 || value != value.trimAscii()) { return false }
    if (value.startsWith("@")) {
        let parts = value[1..].split("/")
        return parts.size == 2 && productPluginNpmNameSegment(parts[0]) &&
            productPluginNpmNameSegment(parts[1])
    }
    let parts = value.split("/")
    parts.size == 1 && productPluginNpmNameSegment(parts[0])
}

func productPluginNpmNameSegment(value: String): Bool {
    if (value == "" || value.startsWith(".") || value.startsWith("_") || value == "..") { return false }
    for (rune in value.toRuneArray()) {
        if (!((rune >= r'a' && rune <= r'z') || (rune >= r'0' && rune <= r'9') ||
            rune == r'.' || rune == r'-' || rune == r'_')) {
            return false
        }
    }
    true
}

func productPluginGitEndpoint(locator: String): PluginImportResult<?ProductPluginSourceEndpoint> {
    if (locator.startsWith("https://")) {
        if (locator.contains("?") || locator.contains("#")) {
            return pluginImportError("plugin.git_locator_invalid", "Git URLs cannot contain a query or fragment")
        }
        let endpoint = match (productPluginUrlEndpoint(locator, "https", true)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        return PluginImportResult.Ok(Some(endpoint))
    }
    if (locator.contains("://") || locator.contains("@") || locator.contains(":")) {
        return pluginImportError(
            "plugin.git_locator_invalid",
            "Git sources must use a local path or an HTTPS URL without embedded credentials"
        )
    }
    PluginImportResult.Ok(None)
}
func productPluginWorkspaceSourceAllowed(
    spec: ProductPluginAcquisitionSpec,
    workspaceRoot: String
): PluginImportResult<Bool> {
    if (!spec.workspaceSource) { return PluginImportResult.Ok(false) }
    try {
        let source = canonicalize(Path(spec.locator)).toString()
        let workspace = canonicalize(Path(workspaceRoot)).toString()
        if (!source.startsWith(workspace + "/")) {
            return pluginImportError(
                "plugin.git_locator_invalid",
                "local Git plugin sources must be directories inside the active workspace"
            )
        }
        let sourceInfo = FileInfo(Path(source))
        if (!sourceInfo.isDirectory()) {
            return pluginImportError(
                "plugin.git_locator_invalid",
                "local Git plugin source is not a directory"
            )
        }
        PluginImportResult.Ok(true)
    } catch (error: Exception) {
        pluginImportError("plugin.git_locator_invalid", error.message)
    }
}

func productPluginRegistryEndpoint(
    registryUrl: String
): PluginImportResult<ProductPluginSourceEndpoint> {
    if (registryUrl == "" || registryUrl != registryUrl.trimAscii() || registryUrl.contains("?") ||
        registryUrl.contains("#") || registryUrl.contains("@")) {
        return pluginImportError("plugin.registry_invalid", "npm registry URL is invalid or contains credentials")
    }
    let scheme = if (registryUrl.startsWith("https://")) { "https" } else if (
        registryUrl.startsWith("http://")
    ) { "http" } else { "" }
    if (scheme == "") {
        return pluginImportError("plugin.registry_invalid", "npm registries must use HTTPS or loopback HTTP")
    }
    let endpoint = match (productPluginUrlEndpoint(registryUrl, scheme, false)) {
        case PluginImportResult.Ok(value) => value
        case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
    }
    if (scheme == "http" && endpoint.host != "127.0.0.1") {
        return pluginImportError("plugin.registry_invalid", "plain HTTP is permitted only for the 127.0.0.1 fixture registry")
    }
    PluginImportResult.Ok(endpoint)
}

func productPluginUrlEndpoint(
    value: String,
    scheme: String,
    requirePath: Bool
): PluginImportResult<ProductPluginSourceEndpoint> {
    let parts = value.split("://")
    if (parts.size != 2 || parts[0] != scheme) {
        return pluginImportError("plugin.url_invalid", "source URL has an unsupported scheme")
    }
    let authorityAndPath = parts[1]
    let pathParts = authorityAndPath.split("/")
    let authority = pathParts[0]
    if (authority == "" || (requirePath && (pathParts.size < 2 || pathParts[1] == ""))) {
        return pluginImportError("plugin.url_invalid", "source URL must include a host and path")
    }
    if (authority.contains("?") || authority.contains("#") || authority.contains("@")) {
        return pluginImportError("plugin.url_invalid", "source URL host cannot contain credentials, query, or fragment")
    }
    let hostParts = authority.split(":")
    if (hostParts.size > 2 || hostParts[0] == "") {
        return pluginImportError("plugin.url_invalid", "source URL host or port is invalid")
    }
    let host = hostParts[0].toAsciiLower()
    for (rune in host.toRuneArray()) {
        if (!((rune >= r'a' && rune <= r'z') || (rune >= r'0' && rune <= r'9') ||
            rune == r'.' || rune == r'-')) {
            return pluginImportError("plugin.url_invalid", "source URL host is invalid")
        }
    }
    var port: UInt16 = if (scheme == "https") { 443u16 } else { 80u16 }
    if (hostParts.size == 2) {
        try {
            let parsed = UInt16.parse(hostParts[1])
            if (parsed == 0u16 || parsed.toString() != hostParts[1]) {
                return pluginImportError("plugin.url_invalid", "source URL port is invalid")
            }
            port = parsed
        } catch (_: Exception) {
            return pluginImportError("plugin.url_invalid", "source URL port is invalid")
        }
    }
    PluginImportResult.Ok(ProductPluginSourceEndpoint(
        host,
        port,
        scheme == "http" && host == "127.0.0.1"
    ))
}

func productPluginRegistryCanonical(value: String): String {
    var result = value
    while (result.endsWith("/")) {
        result = result[0..(result.size - 1)]
    }
    result + "/"
}

func productPluginAcquisitionPolicy(
    shellNetworkMode: ShellNetworkMode,
    gitEndpoint: ?ProductPluginSourceEndpoint,
    registryEndpoint: ProductPluginSourceEndpoint,
    requiresNetwork: Bool
): PluginImportResult<NetworkPolicy> {
    if (!requiresNetwork) {
        return PluginImportResult.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }
    match (shellNetworkMode) {
        case ShellNetworkMode.TrustedHost =>
            PluginImportResult.Ok(NetworkPolicy(NetworkPolicyMode.HostNetwork))
        case ShellNetworkMode.Restricted | ShellNetworkMode.Proxy =>
            let rules = ArrayList<NetworkEgressRule>()
            if (let Some(endpoint) <- gitEndpoint) {
                rules.add(productPluginEgressRule(endpoint))
            }
            rules.add(productPluginEgressRule(registryEndpoint))
            try {
                PluginImportResult.Ok(NetworkPolicy(
                    NetworkPolicyMode.Mediated,
                    egress: rules.toArray()
                ))
            } catch (error: Exception) {
                pluginImportError("plugin.acquisition_network_policy_invalid", error.message)
            }
    }
}

func productPluginEgressRule(endpoint: ProductPluginSourceEndpoint): NetworkEgressRule {
    NetworkEgressRule(
        endpoint.host,
        endpoint.port,
        privateAddresses: if (endpoint.isLoopback) { ["127.0.0.1"] } else { [] }
    )
}

func productPluginShellQuote(value: String): String {
    "'" + value.replace("'", "'\"'\"'") + "'"
}

class ProductPluginSourceAcquirer {
    private let vnext: ProductVnextControl
    private let ids: ProductIds
    private let workspaceRoot: String
    private let settingsRoot: String

    init(
        vnext: ProductVnextControl,
        ids: ProductIds,
        workspaceRoot: String,
        settingsRoot: String
    ) {
        this.vnext = vnext
        this.ids = ids
        this.workspaceRoot = workspaceRoot
        this.settingsRoot = settingsRoot
    }

    func acquire(
        sessionId: SessionId,
        spec: ProductPluginAcquisitionSpec,
        approvalDecision: ApprovalDecision
    ): PluginImportResult<ProductAcquiredPluginSource> {
        if (workspaceRoot.trimAscii() == "") {
            return pluginImportError("plugin.acquisition_workspace_missing", "plugin source acquisition requires a workspace root")
        }
        let stagingParent = match (productPluginAcquisitionRoot(settingsRoot, workspaceRoot)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let mountWorkspace = match (productPluginWorkspaceSourceAllowed(spec, workspaceRoot)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let operationKey = ids.nextOperationId().value
        let stageRoot = stagingParent + "/" + operationKey
        let isGit = match (spec.kind) {
            case PluginSourceKind.Git => true
            case _ => false
        }
        let packageRoot = stageRoot + if (isGit) { "/repo" } else { "/package" }
        let command = if (isGit) {
            gitCommand(stageRoot, spec)
        } else {
            npmCommand(stageRoot, spec)
        }
        let callId = "plugin-acquisition-" + operationKey
        let call = ToolCall(
            callId,
            "plugin_acquisition",
            objectValue([
                ValueField("command", textValue(command)),
                ValueField("network", networkPolicyCanonicalValue(spec.networkPolicy)),
                ValueField("timeout", integerValue(600)),
                ValueField("async", boolValue(false)),
                ValueField("pty", boolValue(false)),
                ValueField("workspace_read_root", textValue(if (mountWorkspace) {
                    workspaceRoot
                } else {
                    ""
                }))
            ])
        )
        let capabilities = pluginAcquisitionCapabilities(
            spec.networkPolicy, workspaceRoot, mountWorkspace
        )
        let execution = vnext.executePluginAcquisitionControl(
            sessionId,
            capabilities,
            call,
            stageRoot,
            approvalDecision: approvalDecision
        )
        match (execution) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                if (result.isError) {
                    cleanupStage(stageRoot)
                    let error = productToolResultError(result)
                    return pluginImportError(
                        "plugin.acquisition_command_failed",
                        error.code + ": " + error.message
                    )
                }
            case Result.Ok(ToolInvocationResult.NeedsApproval(value)) =>
                cleanupStage(stageRoot)
                return pluginImportError(
                    "plugin.acquisition_approval_required",
                    "source acquisition requires approval for operation " + value.operationId.value
                )
            case Result.Ok(ToolInvocationResult.Denied(value)) =>
                cleanupStage(stageRoot)
                return pluginImportError(
                    "plugin.acquisition_denied",
                    value.reason.code + ": " + value.reason.message
                )
            case Result.Err(error) =>
                cleanupStage(stageRoot)
                return pluginImportError(error.code, error.message)
        }
        let verification = verifyAcquiredSource(stageRoot, packageRoot, spec)
        match (verification) {
            case PluginImportResult.Ok(value) => PluginImportResult.Ok(value)
            case PluginImportResult.Err(error) =>
                cleanupStage(stageRoot)
                PluginImportResult.Err(error)
        }
    }

    func cleanup(source: ProductAcquiredPluginSource): Unit {
        cleanupStage(source.stageRoot)
    }

    private func cleanupStage(path: String): Unit {
        try {
            let _ = removeIfExists(Path(path), recursive: true)
        } catch (_: Exception) {
            ()
        }
    }


    private func gitCommand(stageRoot: String, spec: ProductPluginAcquisitionSpec): String {
        let stage = productPluginShellQuote(stageRoot)
        let repo = productPluginShellQuote(stageRoot + "/repo")
        let locator = productPluginShellQuote(spec.locator)
        let revision = productPluginShellQuote(spec.revision)
        let registry = productPluginShellQuote(spec.registryUrl)
        "set -eu\n" +
            "stage=" + stage + "\n" +
            "repo=" + repo + "\n" +
            "mkdir -p -- \"$stage/home\"\n" +
            "export HOME=\"$stage/home\" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0\n" +
            "git -c core.hooksPath=/dev/null clone --no-checkout --no-hardlinks --no-tags -- " + locator + " \"$repo\"\n" +
            "git -C \"$repo\" -c core.hooksPath=/dev/null fetch --no-tags origin " + revision + "\n" +
            "test \"$(git -C \"$repo\" rev-parse FETCH_HEAD)\" = " + revision + "\n" +
            "git -C \"$repo\" -c core.hooksPath=/dev/null checkout --detach " + revision + "\n" +
            "test \"$(git -C \"$repo\" rev-parse HEAD)\" = " + revision + "\n" +
            "rm -rf -- \"$repo/.git\"\n" +
            "symlink=\"$(find \"$repo\" -type l -print -quit)\"\n" +
            "if [ -n \"$symlink\" ]; then printf '%s\\n' 'symlinked package files are not supported' >&2; exit 65; fi\n" +
            "if [ -e \"$repo/.npmrc\" ]; then printf '%s\\n' 'package .npmrc is not supported during acquisition' >&2; exit 65; fi\n" +
            "if [ -f \"$repo/package.json\" ]; then\n" +
            "  rm -rf -- \"$repo/node_modules\"\n" +
            "  cd \"$repo\"\n" +
            "  user_config=\"$stage/npm-userconfig\"\n" +
            "  global_config=\"$stage/npm-globalconfig\"\n" +
            "  : > \"$user_config\"\n" +
            "  : > \"$global_config\"\n" +
            "  export npm_config_cache=\"$stage/npm-cache\" npm_config_userconfig=\"$user_config\" npm_config_globalconfig=\"$global_config\" npm_config_ignore_scripts=true npm_config_bin_links=false npm_config_audit=false npm_config_fund=false npm_config_registry=" + registry + "\n" +
            "  npm install --ignore-scripts --no-bin-links --no-audit --no-fund --registry=" + registry + " --userconfig=\"$user_config\" --globalconfig=\"$global_config\"\n" +
            "  mv -- \"$repo/package-lock.json\" \"$repo/.axyndra-dependencies.lock.json\"\n" +
            "else\n" +
            "  printf '%s\\n' '{\"lockfileVersion\":1,\"packages\":{}}' > \"$repo/.axyndra-dependencies.lock.json\"\n" +
            "fi\n" +
            "symlink=\"$(find \"$repo\" -type l -print -quit)\"\n" +
            "if [ -n \"$symlink\" ]; then printf '%s\\n' 'symlinked package files are not supported' >&2; exit 65; fi\n"
    }

    private func npmCommand(stageRoot: String, spec: ProductPluginAcquisitionSpec): String {
        let stage = productPluginShellQuote(stageRoot)
        let packageSpec = productPluginShellQuote(spec.packageName + "@" + spec.version)
        let packagePath = productPluginShellQuote(stageRoot + "/node_modules/" + spec.packageName)
        let registry = productPluginShellQuote(spec.registryUrl)
        "set -eu\n" +
            "stage=" + stage + "\n" +
            "mkdir -p -- \"$stage/home\"\n" +
            "npm_user_config=\"$stage/npm-userconfig\"\n" +
            "npm_global_config=\"$stage/npm-globalconfig\"\n" +
            ": > \"$npm_user_config\"\n" +
            ": > \"$npm_global_config\"\n" +
            "export HOME=\"$stage/home\" npm_config_cache=\"$stage/npm-cache\" npm_config_userconfig=\"$npm_user_config\" npm_config_globalconfig=\"$npm_global_config\" npm_config_ignore_scripts=true npm_config_bin_links=false npm_config_audit=false npm_config_fund=false npm_config_registry=" + registry + "\n" +
            "cd \"$stage\"\n" +
            "npm install --ignore-scripts --no-bin-links --no-audit --no-fund --save-exact --registry=" + registry + " --userconfig=\"$npm_user_config\" --globalconfig=\"$npm_global_config\" --prefix \"$stage\" -- " + packageSpec + "\n" +
            "test -d " + packagePath + "\n" +
            "mv -- " + packagePath + " \"$stage/package\"\n" +
            "package_symlink=\"$(find \"$stage/package\" -type l -print -quit)\"\n" +
            "if [ -n \"$package_symlink\" ]; then printf '%s\\n' 'symlinked package files are not supported' >&2; exit 65; fi\n" +
            "mkdir -p -- \"$stage/package/node_modules\"\n" +
            "cp -a -- \"$stage/node_modules/.\" \"$stage/package/node_modules/\"\n" +
            "rm -rf -- \"$stage/node_modules\"\n" +
            "mv -- \"$stage/package-lock.json\" \"$stage/package/.axyndra-dependencies.lock.json\"\n" +
            "if [ -e \"$stage/package/.npmrc\" ]; then printf '%s\\n' 'package .npmrc is not supported during acquisition' >&2; exit 65; fi\n" +
            "symlink=\"$(find \"$stage/package\" -type l -print -quit)\"\n" +
            "if [ -n \"$symlink\" ]; then printf '%s\\n' 'symlinked package files are not supported' >&2; exit 65; fi\n"
    }
}

func productPluginAcquisitionRoot(
    settingsRoot: String,
    workspaceRoot: String
): PluginImportResult<String> {
    if (settingsRoot.trimAscii() == "" || workspaceRoot.trimAscii() == "") {
        return pluginImportError(
            "plugin.acquisition_stage_invalid",
            "plugin acquisition requires identified settings and workspace roots"
        )
    }
    try {
        pluginCreateDirectoryTree(settingsRoot)
        let settingsInfo = FileInfo(Path(settingsRoot))
        if (!settingsInfo.isDirectory() || settingsInfo.isSymbolicLink()) {
            return pluginImportError(
                "plugin.acquisition_stage_invalid",
                "plugin acquisition settings root must be a real directory"
            )
        }
        let canonicalSettings = canonicalize(Path(settingsRoot)).toString()
        let canonicalWorkspace = canonicalize(Path(workspaceRoot)).toString()
        if (canonicalSettings == canonicalWorkspace ||
            canonicalSettings.startsWith(canonicalWorkspace + "/")) {
            return pluginImportError(
                "plugin.acquisition_stage_invalid",
                "plugin acquisition staging must be outside the writable workspace"
            )
        }
        let pluginsRoot = canonicalSettings + "/plugins"
        let acquisitionRoot = pluginsRoot + "/acquisition"
        pluginCreateDirectoryTree(acquisitionRoot)
        for (path in [pluginsRoot, acquisitionRoot]) {
            let info = FileInfo(Path(path))
            if (!info.isDirectory() || info.isSymbolicLink()) {
                return pluginImportError(
                    "plugin.acquisition_stage_invalid",
                    "plugin acquisition staging ancestors must be real directories"
                )
            }
        }
        let canonicalRoot = canonicalize(Path(acquisitionRoot)).toString()
        if (!canonicalRoot.startsWith(canonicalSettings + "/") ||
            canonicalRoot == canonicalWorkspace ||
            canonicalRoot.startsWith(canonicalWorkspace + "/")) {
            return pluginImportError(
                "plugin.acquisition_stage_invalid",
                "plugin acquisition staging escaped host-owned settings storage"
            )
        }
        PluginImportResult.Ok(canonicalRoot)
    } catch (error: Exception) {
        pluginImportError("plugin.acquisition_stage_invalid", error.message)
    }
}

func pluginAcquisitionCapabilities(
    policy: NetworkPolicy,
    workspaceRoot: String,
    allowWorkspaceRead: Bool
): CapabilitySet {
    let values = ArrayList<Capability>()
    if (allowWorkspaceRead) {
        values.add(Capability(CapabilityKind.WorkspaceRead, resource: workspaceRoot))
    }
    values.add(Capability(CapabilityKind.WorkspaceWrite))
    values.add(Capability(CapabilityKind.ProcessSpawn))
    for (resource in networkPolicyCapabilityResources(policy)) {
        values.add(Capability(CapabilityKind.NetworkAccess, resource: resource))
    }
    CapabilitySet(values: values.toArray())
}

func productPluginLocalDependencyRange(value: String): Bool {
    let range = value.trimAscii().toAsciiLower()
    range.startsWith("file:") || range.startsWith("link:") ||
        range.startsWith("workspace:") || range.startsWith("./") ||
        range.startsWith("../") || range.startsWith("/") ||
        range.startsWith("~/") || range.startsWith("\\")
}
func verifyAcquiredSource(
    stageRoot: String,
    packageRoot: String,
    spec: ProductPluginAcquisitionSpec
): PluginImportResult<ProductAcquiredPluginSource> {
    try {
        let stageInfo = FileInfo(Path(stageRoot))
        let packageInfo = FileInfo(Path(packageRoot))
        if (stageInfo.isSymbolicLink() || packageInfo.isSymbolicLink() || !packageInfo.isDirectory()) {
            return pluginImportError("plugin.acquisition_stage_invalid", "acquired package is not a regular staged directory")
        }
    } catch (_: Exception) {
        return pluginImportError("plugin.acquisition_stage_missing", "source acquisition did not produce a package directory")
    }
    let descriptor = match (inspectPluginPackage(packageRoot)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
    }
    for (dependency in descriptor.dependencies) {
        if (productPluginLocalDependencyRange(dependency.versionRange)) {
            return pluginImportError(
                "plugin.acquisition_local_dependency_forbidden",
                "remote plugin acquisition does not permit local dependency sources: " + dependency.name
            )
        }
    }
    if (!descriptor.missingDependencies.isEmpty()) {
        return pluginImportError(
            "plugin.acquisition_dependencies_missing",
            "acquired plugin dependencies are incomplete; first missing dependency: " + descriptor.missingDependencies[0]
        )
    }
    match (spec.kind) {
        case PluginSourceKind.Git =>
            PluginImportResult.Ok(ProductAcquiredPluginSource(
                PluginSourceKind.Git,
                spec.sourceLocator,
                descriptor.version,
                spec.revision,
                "",
                packageRoot,
                stageRoot
            ))
        case PluginSourceKind.Npm =>
            let manifest = match (pluginAcquisitionJsonObject(packageRoot + "/package.json")) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let name = match (pluginAcquisitionJsonText(manifest, "name")) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let version = match (pluginAcquisitionJsonText(manifest, "version")) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            if (name != spec.packageName || version != spec.version || descriptor.version != spec.version) {
                return pluginImportError(
                    "plugin.acquisition_identity_mismatch",
                    "npm package name or version does not match the exact requested source"
                )
            }
            let lock = match (pluginAcquisitionJsonObject(
                packageRoot + "/.axyndra-dependencies.lock.json"
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let packages = match (lock.field("packages")) {
                case Some(value) => value
                case None => return pluginImportError("plugin.dependency_lock_invalid", "npm dependency lock has no packages table")
            }
            let entryPath = "node_modules/" + spec.packageName
            let entry = match (packages.field(entryPath)) {
                case Some(value) => value
                case None => return pluginImportError("plugin.dependency_lock_invalid", "npm dependency lock omits the requested package")
            }
            let lockedVersion = match (pluginAcquisitionJsonText(entry, "version")) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let integrity = match (pluginAcquisitionJsonText(entry, "integrity")) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            if (lockedVersion != spec.version || !integrity.startsWith("sha512-") || integrity.size < 24) {
                return pluginImportError(
                    "plugin.acquisition_integrity_invalid",
                    "npm package lock does not contain the exact requested version and SHA-512 integrity"
                )
            }
            PluginImportResult.Ok(ProductAcquiredPluginSource(
                PluginSourceKind.Npm,
                spec.sourceLocator,
                spec.version,
                "",
                integrity,
                packageRoot,
                stageRoot
            ))
        case PluginSourceKind.Local =>
            pluginImportError("plugin.source_kind_invalid", "local plugins use the local-path import API")
    }
}

func pluginAcquisitionJsonObject(path: String): PluginImportResult<JsonNode> {
    try {
        let text = String.fromUtf8(File.readFrom(Path(path)))
        let value = parseUnifiedJson(text, maxBytes: 16777216, maxDepth: 64)
        if (value.unifiedKind != UnifiedJsonKind.Object) {
            return pluginImportError("plugin.dependency_lock_invalid", "acquisition metadata must be a JSON object")
        }
        PluginImportResult.Ok(value)
    } catch (error: Exception) {
        pluginImportError("plugin.acquisition_metadata_invalid", error.message)
    }
}

func pluginAcquisitionJsonText(
    value: JsonNode,
    key: String
): PluginImportResult<String> {
    match (value.field(key)) {
        case Some(field) =>
            if (field.unifiedKind == UnifiedJsonKind.Text) {
                PluginImportResult.Ok(field.text)
            } else {
                pluginImportError("plugin.acquisition_metadata_invalid", "acquisition metadata field must be text: " + key)
            }
        case None => pluginImportError("plugin.acquisition_metadata_invalid", "acquisition metadata field is missing: " + key)
    }
}
