package agent_product

import agent_domain.*
import agent_extensions.*
import agent_mcp.*
import sandbox4cj.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.env.*
import std.fs.*
import std.sync.*

@Derive[Equatable]
public enum ProductMcpTransportKind {
    Stdio | StreamableHttp
}

@Derive[Equatable]
public enum ProductMcpServerStatus {
    Disabled | Starting | Ready | Failed | Stopping | Stopped
}

public class ProductMcpServerSnapshot {
    public let id: String
    public let transport: ProductMcpTransportKind
    public let enabled: Bool
    public let status: ProductMcpServerStatus
    public let sandboxed: Bool
    public let workspaceReadOnly: Bool
    public let networkAllowed: Bool
    public let tools: Array<String>
    public let errorCode: String

    public init(
        id: String,
        transport: ProductMcpTransportKind,
        enabled: Bool,
        status: ProductMcpServerStatus,
        sandboxed!: Bool = false,
        workspaceReadOnly!: Bool = false,
        networkAllowed!: Bool = false,
        tools!: Array<String> = [],
        errorCode!: String = ""
    ) {
        this.id = id
        this.transport = transport
        this.enabled = enabled
        this.status = status
        this.sandboxed = sandboxed
        this.workspaceReadOnly = workspaceReadOnly
        this.networkAllowed = networkAllowed
        this.tools = tools
        this.errorCode = errorCode
    }
}

public func productMcpTransportName(kind: ProductMcpTransportKind): String {
    match (kind) {
        case ProductMcpTransportKind.Stdio => "stdio"
        case ProductMcpTransportKind.StreamableHttp => "streamable-http"
    }
}

public func productMcpStatusName(status: ProductMcpServerStatus): String {
    match (status) {
        case ProductMcpServerStatus.Disabled => "disabled"
        case ProductMcpServerStatus.Starting => "starting"
        case ProductMcpServerStatus.Ready => "ready"
        case ProductMcpServerStatus.Failed => "failed"
        case ProductMcpServerStatus.Stopping => "stopping"
        case ProductMcpServerStatus.Stopped => "stopped"
    }
}

class ProductMcpServerConfig {
    let id: String
    let enabled: Bool
    let transport: ProductMcpTransportKind
    let networkAllowed: Bool
    let secretEnvironmentTargets: Array<String>
    let trustedReadOnlyTools: Array<String>
    let stdio: ?McpStdioTransportConfig
    let http: ?McpStreamableHttpClientConfig

    init(
        id: String,
        enabled: Bool,
        transport: ProductMcpTransportKind,
        networkAllowed!: Bool = false,
        secretEnvironmentTargets!: Array<String> = [],
        trustedReadOnlyTools!: Array<String> = [],
        stdio!: ?McpStdioTransportConfig = None,
        http!: ?McpStreamableHttpClientConfig = None
    ) {
        this.id = id
        this.enabled = enabled
        this.transport = transport
        this.networkAllowed = networkAllowed
        this.secretEnvironmentTargets = secretEnvironmentTargets
        this.trustedReadOnlyTools = trustedReadOnlyTools
        this.stdio = stdio
        this.http = http
    }
}

class ProductMcpRecord {
    let config: ProductMcpServerConfig
    var status: ProductMcpServerStatus
    var client: ?McpClient = None
    var tools: Array<String> = []
    var errorCode: String = ""

    init(config: ProductMcpServerConfig) {
        this.config = config
        this.status = if (config.enabled) {
            ProductMcpServerStatus.Starting
        } else {
            ProductMcpServerStatus.Disabled
        }
    }
}

class ProductMcpRuntime {
    private let records: ArrayList<ProductMcpRecord>
    private let lock = Mutex()
    private var closed = false
    private var closeError: ?AgentError = None

    init(configs: Array<ProductMcpServerConfig>) {
        this.records = ArrayList<ProductMcpRecord>()
        for (config in configs) {
            records.add(ProductMcpRecord(config))
        }
    }

    func recordsForStartup(): Array<ProductMcpRecord> {
        lock.lock()
        try { records.toArray() } finally { lock.unlock() }
    }

    func attach(record: ProductMcpRecord, client: McpClient): Unit {
        lock.lock()
        try { record.client = Some(client) } finally { lock.unlock() }
    }

    func markReady(record: ProductMcpRecord, tools: Array<String>): Unit {
        lock.lock()
        try {
            record.status = ProductMcpServerStatus.Ready
            record.tools = tools
            record.errorCode = ""
        } finally {
            lock.unlock()
        }
    }

    func markFailed(record: ProductMcpRecord, code: String): Unit {
        lock.lock()
        try {
            record.status = ProductMcpServerStatus.Failed
            record.errorCode = code
        } finally {
            lock.unlock()
        }
    }

    func snapshots(): Array<ProductMcpServerSnapshot> {
        lock.lock()
        try {
            let values = ArrayList<ProductMcpServerSnapshot>()
            for (record in records) {
                values.add(ProductMcpServerSnapshot(
                    record.config.id,
                    record.config.transport,
                    record.config.enabled,
                    record.status,
                    sandboxed: record.config.transport == ProductMcpTransportKind.Stdio,
                    workspaceReadOnly: record.config.transport == ProductMcpTransportKind.Stdio,
                    networkAllowed: record.config.networkAllowed,
                    tools: record.tools,
                    errorCode: record.errorCode
                ))
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }

    func status(serverId: String): ?ProductMcpServerSnapshot {
        lock.lock()
        try {
            for (record in records where record.config.id == serverId) {
                return Some(ProductMcpServerSnapshot(
                    record.config.id,
                    record.config.transport,
                    record.config.enabled,
                    record.status,
                    sandboxed: record.config.transport == ProductMcpTransportKind.Stdio,
                    workspaceReadOnly: record.config.transport == ProductMcpTransportKind.Stdio,
                    networkAllowed: record.config.networkAllowed,
                    tools: record.tools,
                    errorCode: record.errorCode
                ))
            }
            None
        } finally {
            lock.unlock()
        }
    }

    func cancel(runId: RunId): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            var first: ?AgentError = None
            for (record in records where record.status == ProductMcpServerStatus.Ready) {
                match (record.client) {
                    case Some(client) => match (client.cancel(runId.value)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => if (first.isNone()) { first = Some(error) }
                    }
                    case None => ()
                }
            }
            match (first) {
                case Some(error) => Result.Err(error)
                case None => Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
    }

    func close(): Result<Unit> {
        lock.lock()
        try {
            if (closed) {
                return match (closeError) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            closed = true
            let failures = ArrayList<ErrorField>()
            var failureCount: Int64 = 0
            for (record in records) {
                match (record.client) {
                    case Some(client) =>
                        record.status = ProductMcpServerStatus.Stopping
                        match (client.close()) {
                            case Result.Ok(_) =>
                                record.status = ProductMcpServerStatus.Stopped
                                record.errorCode = ""
                            case Result.Err(error) =>
                                record.status = ProductMcpServerStatus.Failed
                                record.errorCode = error.code
                                failures.add(ErrorField(
                                    "server_" + failureCount.toString(),
                                    record.config.id
                                ))
                                failures.add(ErrorField(
                                    "error_" + failureCount.toString(),
                                    error.code
                                ))
                                failureCount++
                        }
                    case None => ()
                }
            }
            if (failureCount > 0) {
                failures.add(ErrorField("failure_count", failureCount.toString()))
                let error = AgentError(
                    AgentErrorKind.Internal,
                    "mcp.product_close_failed",
                    "failed to close " + failureCount.toString() +
                        " MCP server connection(s)",
                    fields: failures.toArray()
                )
                closeError = Some(error)
                Result.Err(error)
            } else {
                Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
    }
}

class ProductMcpYamlField {
    let name: String
    let value: String

    init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

class ProductMcpNameBinding {
    let target: String
    let source: String

    init(target: String, source: String) {
        this.target = target
        this.source = source
    }
}

class ProductMcpServerDraft {
    var id: String = ""
    var enabled: ?Bool = None
    var transport: String = ""
    var command: String = ""
    let arguments = ArrayList<String>()
    var cwd: String = ""
    let environment = ArrayList<ProductMcpNameBinding>()
    let secretEnvironment = ArrayList<ProductMcpNameBinding>()
    let trustedReadOnlyTools = ArrayList<String>()
    var networkAllowed: Bool = false
    var url: String = ""
    var bearerTokenEnvironment: String = ""
    var origin: String = ""
    var preferSse: Bool = false
    let headers = ArrayList<ProductMcpNameBinding>()
    var maxFrameBytes: Int64 = 8388608
    var requestTimeoutMillis: Int64 = 30000
    var gracefulShutdownMillis: Int64 = 3000
    let fields = ArrayList<String>()
    let environmentTargets = ArrayList<String>()
    let headerNames = ArrayList<String>()

    func mark(name: String): Unit {
        if (containsString(fields, name)) {
            throw IllegalArgumentException("duplicate MCP server field: " + name)
        }
        fields.add(name)
    }

    func has(name: String): Bool { containsString(fields, name) }

    func addEnvironment(target: String, source: String, secret!: Bool = false): Unit {
        if (containsString(environmentTargets, target)) {
            throw IllegalArgumentException("duplicate MCP environment target")
        }
        environmentTargets.add(target)
        if (secret) {
            secretEnvironment.add(ProductMcpNameBinding(target, source))
        } else {
            environment.add(ProductMcpNameBinding(target, source))
        }
    }

    func addHeader(header: String, environmentName: String): Unit {
        let normalized = header.toAsciiLower()
        if (containsString(headerNames, normalized)) {
            throw IllegalArgumentException("duplicate MCP HTTP header")
        }
        headerNames.add(normalized)
        headers.add(ProductMcpNameBinding(header, environmentName))
    }
}

func emptyProductMcpRuntime(): ProductMcpRuntime {
    ProductMcpRuntime([])
}

func loadProductMcpConfig(root: String): Result<Array<ProductMcpServerConfig>> {
    let path = root + "/mcp.yml"
    if (!exists(Path(path))) { return Result.Ok([]) }
    try {
        let bytes = File.readFrom(path)
        if (bytes.size > 1048576) {
            throw IllegalArgumentException("mcp.yml exceeds the 1 MiB configuration limit")
        }
        let source = String.fromUtf8(bytes)
        if (source.indexOf("\u{0}").isSome()) {
            throw IllegalArgumentException("mcp.yml contains NUL")
        }
        Result.Ok(parseProductMcpConfig(source))
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "mcp.product_config_invalid",
            "cannot load mcp.yml: " + error.message,
            fields: [ErrorField("path", path)]
        ))
    }
}

func parseProductMcpConfig(source: String): Array<ProductMcpServerConfig> {
    var versionSeen = false
    var serversSeen = false
    var current: ?ProductMcpServerDraft = None
    var section = ""
    let drafts = ArrayList<ProductMcpServerDraft>()
    var lineNumber: Int64 = 0

    for (line in source.split("\n")) {
        lineNumber += 1
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) { continue }
        if (productMcpIndentedTab(line)) {
            throw IllegalArgumentException("mcp.yml indentation must use spaces at line " + lineNumber.toString())
        }
        let indent = yamlIndent(line)
        if (indent == 0) {
            if (current.isSome()) {
                throw IllegalArgumentException("mcp.yml top-level field follows server entries")
            }
            section = ""
            let field = productMcpYamlField(trimmed)
            match (field.name) {
                case "version" =>
                    if (versionSeen) { throw IllegalArgumentException("duplicate mcp.yml version") }
                    versionSeen = true
                    if (yamlScalar(field.value) != "1") {
                        throw IllegalArgumentException("mcp.yml version must be 1")
                    }
                case "servers" =>
                    if (serversSeen) { throw IllegalArgumentException("duplicate mcp.yml servers") }
                    if (yamlScalar(field.value) != "") {
                        throw IllegalArgumentException("mcp.yml servers must be a block list")
                    }
                    serversSeen = true
                case _ => throw IllegalArgumentException("unknown mcp.yml top-level field")
            }
            continue
        }
        if (!serversSeen) {
            throw IllegalArgumentException("mcp.yml server entry appears before servers")
        }
        if (indent == 2) {
            section = ""
            if (!trimmed.startsWith("- ")) {
                throw IllegalArgumentException("mcp.yml servers must be a block list")
            }
            match (current) {
                case Some(value) => drafts.add(value)
                case None => ()
            }
            let draft = ProductMcpServerDraft()
            let field = productMcpYamlField(trimmed[2..].trimAscii())
            applyProductMcpServerField(draft, field)
            current = Some(draft)
            continue
        }
        let draft = match (current) {
            case Some(value) => value
            case None => throw IllegalArgumentException("mcp.yml field appears before a server entry")
        }
        if (indent == 4) {
            let field = productMcpYamlField(trimmed)
            if (field.name == "args" || field.name == "env" ||
                field.name == "secret_env" || field.name == "headers" ||
                field.name == "trusted_read_only_tools") {
                draft.mark(field.name)
                if (yamlScalar(field.value) != "") {
                    throw IllegalArgumentException("MCP " + field.name + " must use block syntax")
                }
                section = field.name
            } else {
                section = ""
                applyProductMcpServerField(draft, field)
            }
            continue
        }
        if (indent == 6) {
            match (section) {
                case "args" =>
                    if (!trimmed.startsWith("- ")) {
                        throw IllegalArgumentException("MCP args must be a block list")
                    }
                    draft.arguments.add(yamlScalar(trimmed[2..].trimAscii()))
                case "env" =>
                    let field = productMcpYamlField(trimmed)
                    let sourceName = yamlScalar(field.value)
                    if (field.name == "" || sourceName == "") {
                        throw IllegalArgumentException("MCP env maps variable names to variable names")
                    }
                    draft.addEnvironment(field.name, sourceName)
                case "secret_env" =>
                    let field = productMcpYamlField(trimmed)
                    let sourceName = yamlScalar(field.value)
                    if (field.name == "" || sourceName == "") {
                        throw IllegalArgumentException(
                            "MCP secret_env maps variable names to variable names"
                        )
                    }
                    draft.addEnvironment(field.name, sourceName, secret: true)
                case "headers" =>
                    let field = productMcpYamlField(trimmed)
                    let environmentName = yamlScalar(field.value)
                    if (field.name == "" || environmentName == "") {
                        throw IllegalArgumentException("MCP headers map header names to environment names")
                    }
                    draft.addHeader(field.name, environmentName)
                case "trusted_read_only_tools" =>
                    if (!trimmed.startsWith("- ")) {
                        throw IllegalArgumentException(
                            "MCP trusted_read_only_tools must be a block list"
                        )
                    }
                    let toolName = yamlScalar(trimmed[2..].trimAscii())
                    if (toolName == "" || containsString(
                        draft.trustedReadOnlyTools,
                        toolName
                    )) {
                        throw IllegalArgumentException(
                            "MCP trusted read-only tool names must be unique and non-empty"
                        )
                    }
                    draft.trustedReadOnlyTools.add(toolName)
                case _ => throw IllegalArgumentException("unexpected nested mcp.yml field")
            }
            continue
        }
        throw IllegalArgumentException("mcp.yml uses unsupported indentation at line " + lineNumber.toString())
    }
    match (current) {
        case Some(value) => drafts.add(value)
        case None => ()
    }
    if (!versionSeen || !serversSeen) {
        throw IllegalArgumentException("mcp.yml requires version and servers")
    }

    let configs = ArrayList<ProductMcpServerConfig>()
    let ids = ArrayList<String>()
    for (draft in drafts) {
        let config = finalizeProductMcpServer(draft)
        if (containsString(ids, config.id)) {
            throw IllegalArgumentException("duplicate MCP server id")
        }
        ids.add(config.id)
        configs.add(config)
    }
    configs.toArray()
}

func productMcpYamlField(source: String): ProductMcpYamlField {
    let separator = source.indexOf(":")
    if (separator.isNone()) {
        throw IllegalArgumentException("mcp.yml fields require ':'")
    }
    let index = separator.getOrThrow()
    let name = source[..index].trimAscii()
    if (name == "") { throw IllegalArgumentException("mcp.yml field name is empty") }
    ProductMcpYamlField(name, source[index + 1..].trimAscii())
}

func applyProductMcpServerField(
    draft: ProductMcpServerDraft,
    field: ProductMcpYamlField
): Unit {
    draft.mark(field.name)
    let value = yamlScalar(field.value)
    match (field.name) {
        case "id" => draft.id = value
        case "enabled" => draft.enabled = Some(parseConfigBool("MCP enabled", value))
        case "transport" => draft.transport = value
        case "command" => draft.command = value
        case "cwd" => draft.cwd = value
        case "network" => draft.networkAllowed = parseConfigBool("MCP network", value)
        case "url" => draft.url = value
        case "bearer_token_env" => draft.bearerTokenEnvironment = value
        case "origin" => draft.origin = value
        case "prefer_sse" => draft.preferSse = parseConfigBool("MCP prefer_sse", value)
        case "max_frame_bytes" => draft.maxFrameBytes = productMcpInteger(field.name, value)
        case "request_timeout_ms" => draft.requestTimeoutMillis = productMcpInteger(field.name, value)
        case "graceful_shutdown_ms" => draft.gracefulShutdownMillis = productMcpInteger(field.name, value)
        case _ => throw IllegalArgumentException("unknown MCP server field: " + field.name)
    }
}

func productMcpInteger(name: String, value: String): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        throw IllegalArgumentException("MCP " + name + " must be an integer")
    }
}

func finalizeProductMcpServer(draft: ProductMcpServerDraft): ProductMcpServerConfig {
    if (!draft.has("id") || draft.id == "" || !isSafeProfileId(draft.id)) {
        throw IllegalArgumentException("MCP server id must use letters, digits, '-' or '_'")
    }
    let enabled = match (draft.enabled) {
        case Some(value) => value
        case None => throw IllegalArgumentException("MCP server enabled must be explicit")
    }
    if (!draft.has("transport")) {
        throw IllegalArgumentException("MCP server transport is required")
    }
    let framing = McpFramingConfig(
        maxFrameBytes: draft.maxFrameBytes,
        requestTimeoutMillis: draft.requestTimeoutMillis,
        gracefulShutdownMillis: draft.gracefulShutdownMillis
    )
    match (draft.transport) {
        case "stdio" =>
            if (!draft.has("command") || draft.command == "") {
                throw IllegalArgumentException("MCP stdio command is required")
            }
            if (draft.has("url") || draft.has("bearer_token_env") || draft.has("origin") ||
                draft.has("prefer_sse") || draft.has("headers")) {
                throw IllegalArgumentException("MCP stdio server contains HTTP-only fields")
            }
            let bindings = ArrayList<McpEnvironmentBinding>()
            for (binding in draft.environment) {
                if (productMcpSecretEnvironmentName(binding.target) ||
                    productMcpSecretEnvironmentName(binding.source)) {
                    throw IllegalArgumentException(
                        "secret-like MCP environment bindings must use secret_env"
                    )
                }
                bindings.add(McpEnvironmentBinding(binding.target, binding.source))
            }
            let secretTargets = ArrayList<String>()
            for (binding in draft.secretEnvironment) {
                bindings.add(McpEnvironmentBinding(binding.target, binding.source))
                secretTargets.add(binding.target)
            }
            ProductMcpServerConfig(
                draft.id,
                enabled,
                ProductMcpTransportKind.Stdio,
                networkAllowed: draft.networkAllowed,
                secretEnvironmentTargets: secretTargets.toArray(),
                trustedReadOnlyTools: draft.trustedReadOnlyTools.toArray(),
                stdio: Some(McpStdioTransportConfig(
                    draft.command,
                    arguments: draft.arguments.toArray(),
                    cwd: draft.cwd,
                    environment: bindings.toArray(),
                    framing: framing
                ))
            )
        case "streamable-http" =>
            if (!draft.has("url") || draft.url == "") {
                throw IllegalArgumentException("MCP Streamable HTTP url is required")
            }
            if (draft.has("command") || draft.has("args") || draft.has("cwd") ||
                draft.has("env") || draft.has("secret_env")) {
                throw IllegalArgumentException("MCP Streamable HTTP server contains stdio-only fields")
            }
            if (draft.has("network")) {
                throw IllegalArgumentException("MCP network is only valid for stdio servers")
            }
            let headers = ArrayList<McpHttpHeaderBinding>()
            for (binding in draft.headers) {
                headers.add(McpHttpHeaderBinding(binding.target, binding.source))
            }
            ProductMcpServerConfig(
                draft.id,
                enabled,
                ProductMcpTransportKind.StreamableHttp,
                networkAllowed: true,
                trustedReadOnlyTools: draft.trustedReadOnlyTools.toArray(),
                http: Some(McpStreamableHttpClientConfig(
                    draft.url,
                    bearerTokenEnvironment: draft.bearerTokenEnvironment,
                    headers: headers.toArray(),
                    origin: draft.origin,
                    preferSse: draft.preferSse,
                    framing: framing
                ))
            )
        case _ => throw IllegalArgumentException("MCP transport must be stdio or streamable-http")
    }
}

func productMcpSecretEnvironmentName(name: String): Bool {
    let normalized = name.toAsciiUpper().replace("-", "_")
    normalized.contains("SECRET") || normalized.contains("TOKEN") ||
        normalized.contains("PASSWORD") || normalized.contains("PASSWD") ||
        normalized.contains("CREDENTIAL") || normalized.endsWith("_KEY") ||
        normalized.contains("API_KEY") || normalized == "SSH_AUTH_SOCK" ||
        normalized.contains("COOKIE")
}

func productMcpIndentedTab(line: String): Bool {
    for (byte in unsafe { line.rawData() }) {
        if (byte == b'\t') { return true }
        if (byte != b' ') { return false }
    }
    false
}

class ProductMcpResolvedEnvironment {
    let entries: Array<SandboxEnvironmentEntry>
    let secretTargets: Array<String>
    let redactor: SecretRedactor

    init(
        entries: Array<SandboxEnvironmentEntry>,
        secretTargets: Array<String>,
        secretValues: Array<String>
    ) {
        this.entries = entries
        this.secretTargets = secretTargets
        this.redactor = SecretRedactor(secretValues)
    }
}

class ProductMcpTransportHandle {
    let transport: McpTransport
    let redactor: SecretRedactor

    init(transport: McpTransport, redactor: SecretRedactor) {
        this.transport = transport
        this.redactor = redactor
    }
}

func openProductMcpTransport(
    config: ProductMcpServerConfig,
    workspaceRoot: String
): Result<ProductMcpTransportHandle> {
    match (config.transport) {
        case ProductMcpTransportKind.Stdio => match (config.stdio) {
            case Some(stdio) => match (openSandboxedProductMcpStdio(
                stdio,
                workspaceRoot,
                config.networkAllowed,
                config.secretEnvironmentTargets
            )) {
                case Result.Ok(value) => Result.Ok(value)
                case Result.Err(error) => Result.Err(error)
            }
            case None => productMcpInternalTransportError()
        }
        case ProductMcpTransportKind.StreamableHttp => match (config.http) {
            case Some(http) =>
                // The HTTP transport resolves bearer and custom-header values
                // from the process environment.  Bind those same values to the
                // product redaction boundary before discovery can project any
                // remote-authored text into the catalog, pipeline, persistence,
                // or model context.  Only the redactor escapes this function;
                // resolved credentials never enter config/status snapshots.
                let redactor = productMcpHttpSecretRedactor(http)
                match (openStreamableHttpMcpTransport(http)) {
                    case Result.Ok(value) => Result.Ok(ProductMcpTransportHandle(
                        value,
                        redactor
                    ))
                    case Result.Err(error) => Result.Err(productMcpRedactError(error, redactor))
                }
            case None => productMcpInternalTransportError()
        }
    }
}

func productMcpHttpSecretRedactor(
    config: McpStreamableHttpClientConfig
): SecretRedactor {
    let values = ArrayList<String>()
    productMcpAddEnvironmentSecret(values, config.bearerTokenEnvironment)
    for (binding in config.headers) {
        productMcpAddEnvironmentSecret(values, binding.environment)
    }
    SecretRedactor(values.toArray())
}

func productMcpAddEnvironmentSecret(
    values: ArrayList<String>,
    environment: String
): Unit {
    if (environment == "") { return }
    match (getVariable(environment)) {
        case Some(value) => values.add(value)
        case None => ()
    }
}

func openSandboxedProductMcpStdio(
    config: McpStdioTransportConfig,
    workspaceRoot: String,
    networkAllowed: Bool,
    secretTargets: Array<String>
): Result<ProductMcpTransportHandle> {
    let resolved = match (resolveProductMcpEnvironment(
        config.environment,
        secretTargets
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let allowedNames = ArrayList<String>()
    for (entry in resolved.entries) { allowedNames.add(entry.name) }
    let toolchain = configuredProductSandboxToolchain()
    let sandbox = try {
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            workspaceRoot,
            filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
            process: ProcessIsolationMode.Isolated,
            network: if (networkAllowed) {
                NetworkIsolationMode.Allowed
            } else {
                NetworkIsolationMode.Denied
            },
            environment: EnvironmentFilter(
                allowlist: allowedNames.toArray(),
                allowedSecrets: resolved.secretTargets,
                secretValues: productMcpSecretValues(resolved.entries, resolved.secretTargets)
            ),
            resources: defaultProductSandboxResourceLimits(),
            readOnlyMounts: toolchain.mounts,
            pathEntries: toolchain.pathEntries
        ))
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "mcp.product_sandbox_invalid",
            "cannot construct the MCP workspace sandbox: " + error.message
        ))
    }
    match (sandbox.availability()) {
        case SandboxResult.Ok(_) => ()
        case SandboxResult.Err(error) => return Result.Err(productMcpRedactError(sandboxAgentError(error), resolved.redactor))
    }
    let plan = match (sandbox.plan(WorkspaceSandboxCommand(
        config.command,
        arguments: config.arguments,
        workingDirectory: config.cwd,
        environment: resolved.entries,
        timeoutMillis: config.framing.requestTimeoutMillis
    ))) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return Result.Err(productMcpRedactError(sandboxAgentError(error), resolved.redactor))
    }
    // A persistent MCP server is not a one-shot command. Deliberately launch
    // the raw bwrap plan rather than its GNU timeout wrapper; individual MCP
    // requests retain their own framing deadline and close owns child reaping.
    let sandboxed = try {
        McpStdioTransportConfig(
            plan.sandboxExecutable,
            arguments: plan.sandboxArguments,
            cwd: "",
            environment: [],
            framing: config.framing
        )
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "mcp.product_sandbox_plan_invalid",
            "cannot adopt the MCP workspace sandbox plan: " + error.message
        ))
    }
    match (openStdioMcpTransport(sandboxed)) {
        case Result.Ok(value) => Result.Ok(ProductMcpTransportHandle(value, resolved.redactor))
        case Result.Err(error) => Result.Err(productMcpRedactError(error, resolved.redactor))
    }
}

func resolveProductMcpEnvironment(
    bindings: Array<McpEnvironmentBinding>,
    secretTargets: Array<String>
): Result<ProductMcpResolvedEnvironment> {
    let variables = getVariables()
    let values = ArrayList<SandboxEnvironmentEntry>()
    for (binding in bindings) {
        var found = false
        for ((name, value) in variables where name == binding.source) {
            try {
                values.add(SandboxEnvironmentEntry(binding.target, value))
            } catch (error: Exception) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "mcp.product_environment_invalid",
                    "MCP stdio environment mapping is invalid: " + error.message,
                    fields: [ErrorField("environment", binding.source)]
                ))
            }
            found = true
            break
        }
        if (!found) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "mcp.stdio_environment_missing",
                "required MCP stdio environment variable is unavailable",
                fields: [ErrorField("environment", binding.source)]
            ))
        }
    }
    let entries = values.toArray()
    Result.Ok(ProductMcpResolvedEnvironment(
        entries,
        secretTargets,
        productMcpSecretValues(entries, secretTargets)
    ))
}

func productMcpSecretValues(
    entries: Array<SandboxEnvironmentEntry>,
    secretTargets: Array<String>
): Array<String> {
    let values = ArrayList<String>()
    for (entry in entries) {
        for (target in secretTargets where target == entry.name) {
            values.add(entry.value)
            break
        }
    }
    values.toArray()
}

func productMcpRedactError(error: AgentError, redactor: SecretRedactor): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) {
        fields.add(ErrorField(field.name, redactor.redact(field.value)))
    }
    AgentError(
        error.kind,
        error.code,
        redactor.redact(error.message),
        retryable: error.retryable,
        fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray()
    )
}

func productMcpInternalTransportError(): Result<ProductMcpTransportHandle> {
    Result.Err(AgentError(
        AgentErrorKind.Internal,
        "mcp.product_transport_missing",
        "validated MCP server is missing its transport configuration"
    ))
}

func startProductMcp(
    settingsRoot: String,
    workspaceRoot: String,
    catalog: ToolCatalog,
    extensions: ExtensionInstaller
): Result<ProductMcpRuntime> {
    let configs = match (loadProductMcpConfig(settingsRoot)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let runtime = ProductMcpRuntime(configs)
    let aliases = McpToolAliasRegistry()
    for (record in runtime.recordsForStartup() where record.config.enabled) {
        let opened = match (openProductMcpTransport(record.config, workspaceRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return failedProductMcpStartup(runtime, record, error)
        }
        let client = McpClient(
            opened.transport,
            McpRequestMeta(McpImplementationInfo("axyndra", "1.0.0", title: "axyndra"))
        )
        runtime.attach(record, client)
        let extension = match (discoverMcpExtension(
            record.config.id,
            client,
            agentUtcMillis(),
            aliases: aliases,
            redact: { value => opened.redactor.redact(value) },
            trustedReadOnlyTools: record.config.trustedReadOnlyTools
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return failedProductMcpStartup(runtime, record, error)
        }
        match (extensions.installTrusted(extension, catalog, source: "mcp.yml")) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                return failedProductMcpStartup(runtime, record, error)
        }
        let tools = ArrayList<String>()
        for (contribution in extension.tools()) {
            tools.add(contribution.descriptor.definition.name)
        }
        runtime.markReady(record, tools.toArray())
    }
    Result.Ok(runtime)
}

func failedProductMcpStartup(
    runtime: ProductMcpRuntime,
    record: ProductMcpRecord,
    source: AgentError
): Result<ProductMcpRuntime> {
    runtime.markFailed(record, source.code)
    let startup = productMcpServerError(record.config.id, source)
    match (runtime.close()) {
        case Result.Ok(_) => Result.Err(startup)
        case Result.Err(closeError) =>
            let fields = ArrayList<ErrorField>()
            fields.add(ErrorField("server", record.config.id))
            fields.add(ErrorField("startup_code", startup.code))
            fields.add(ErrorField("close_code", closeError.code))
            for (field in startup.fields) {
                fields.add(ErrorField("startup_" + field.name, field.value))
            }
            for (field in closeError.fields) {
                fields.add(ErrorField("close_" + field.name, field.value))
            }
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "mcp.product_start_cleanup_failed",
                "MCP startup failed and already-started connections did not close cleanly",
                fields: fields.toArray()
            ))
    }
}

func productMcpServerError(serverId: String, source: AgentError): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in source.fields) { fields.add(field) }
    fields.add(ErrorField("server", serverId))
    AgentError(
        source.kind,
        source.code,
        source.message,
        retryable: source.retryable,
        fallbackAllowed: source.fallbackAllowed,
        fields: fields.toArray()
    )
}
