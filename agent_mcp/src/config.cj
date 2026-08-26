package agent_mcp

import yjson_support.*

import yjson.*

import process4cj.*
import mcp4cj as library

import agent_domain.*
import std.collection.*

public type McpTransportKind = library.McpTransportKind
public type McpLifecycleState = library.McpLifecycleState
public type McpFramingConfig = library.McpFramingConfig

public class McpLifecycle {
    private let primitive = library.McpLifecycle()

    public init() {}

    public func state(): McpLifecycleState { primitive.state() }

    public func transition(next: McpLifecycleState): Result<Unit> {
        match (primitive.transition(next)) {
            case library.McpResult.Ok(_) => Result.Ok(())
            case library.McpResult.Err(error) => Result.Err(AgentError(
                AgentErrorKind.Conflict,
                error.code,
                error.message,
                fields: [ErrorField("mcp_error_kind", "lifecycle")]
            ))
        }
    }
}

public class McpEnvironmentBinding {
    public let target: String
    public let source: String

    public init(target: String, source: String) {
        if (!validEnvironmentName(target) || !validEnvironmentName(source)) {
            throw IllegalArgumentException("MCP environment bindings require valid variable names")
        }
        this.target = target
        this.source = source
    }
}

public class McpStdioTransportConfig {
    public let command: String
    public let arguments: Array<String>
    public let cwd: String
    public let environment: Array<McpEnvironmentBinding>
    public let framing: McpFramingConfig

    public init(
        command: String,
        arguments!: Array<String> = [],
        cwd!: String = "",
        environment!: Array<McpEnvironmentBinding> = [],
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (command.trimAscii() == "" || command.indexOf("\n").isSome()) {
            throw IllegalArgumentException("MCP stdio command must be one executable, not a shell command")
        }
        for (argument in arguments where argument.indexOf("\u{0}").isSome()) {
            throw IllegalArgumentException("MCP stdio argument contains NUL")
        }
        this.command = command
        this.arguments = arguments
        this.cwd = cwd
        this.environment = environment
        this.framing = framing
    }
}

public class McpHttpHeaderBinding {
    public let header: String
    public let environment: String

    public init(header: String, environment: String) {
        if (!validHeaderName(header) || !validEnvironmentName(environment)) {
            throw IllegalArgumentException("invalid MCP HTTP header binding")
        }
        this.header = header
        this.environment = environment
    }
}

public class McpStreamableHttpClientConfig {
    public let url: String
    public let bearerTokenEnvironment: String
    public let headers: Array<McpHttpHeaderBinding>
    public let origin: String
    public let preferSse: Bool
    public let framing: McpFramingConfig

    public init(
        url: String,
        bearerTokenEnvironment!: String = "",
        headers!: Array<McpHttpHeaderBinding> = [],
        origin!: String = "",
        preferSse!: Bool = false,
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (!secureMcpUrl(url)) {
            throw IllegalArgumentException("MCP HTTP URL must use HTTPS or loopback HTTP")
        }
        if (bearerTokenEnvironment != "" && !validEnvironmentName(bearerTokenEnvironment)) {
            throw IllegalArgumentException("invalid MCP bearer token environment variable")
        }
        if (origin != "" && !secureMcpOrigin(origin)) {
            throw IllegalArgumentException("MCP HTTP Origin must use HTTPS or a loopback HTTP origin")
        }
        for (binding in headers where reservedMcpHttpHeader(binding.header)) {
            throw IllegalArgumentException("MCP HTTP custom bindings cannot replace protocol or security headers")
        }
        this.url = url
        this.bearerTokenEnvironment = bearerTokenEnvironment
        this.headers = headers
        this.origin = origin
        this.preferSse = preferSse
        this.framing = framing
    }
}

public class McpStreamableHttpServerConfig {
    public let bindHost: String
    public let port: Int64
    public let bearerTokenEnvironment: String
    public let originAllowlist: Array<String>
    public let externalTls: Bool
    public let trustProxy: Bool
    public let maxConcurrentRequests: Int64
    public let framing: McpFramingConfig

    public init(
        bindHost!: String = "127.0.0.1",
        port!: Int64 = 0,
        bearerTokenEnvironment!: String = "",
        originAllowlist!: Array<String> = [],
        externalTls!: Bool = false,
        trustProxy!: Bool = false,
        maxConcurrentRequests!: Int64 = 16,
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (bindHost.trimAscii() == "" || port < 0 || port > 65535 || maxConcurrentRequests <= 0) {
            throw IllegalArgumentException("invalid MCP HTTP server address or limits")
        }
        if (bearerTokenEnvironment != "" && !validEnvironmentName(bearerTokenEnvironment)) {
            throw IllegalArgumentException("invalid MCP bearer token environment variable")
        }
        if (!loopbackHost(bindHost) &&
            (bearerTokenEnvironment == "" || !externalTls || !trustProxy)) {
            throw IllegalArgumentException(
                "non-loopback MCP HTTP requires bearer auth and a trusted external TLS proxy"
            )
        }
        for (origin in originAllowlist where !secureMcpOrigin(origin)) {
            throw IllegalArgumentException("MCP HTTP origin allowlist contains an insecure origin")
        }
        this.bindHost = bindHost
        this.port = port
        this.bearerTokenEnvironment = bearerTokenEnvironment
        this.originAllowlist = originAllowlist
        this.externalTls = externalTls
        this.trustProxy = trustProxy
        this.maxConcurrentRequests = maxConcurrentRequests
        this.framing = framing
    }
}

public class McpHttpRequestMetadata {
    public let protocolVersion: String
    public let method: String
    public let name: String
    public let origin: String

    public init(
        protocolVersion: String,
        method: String,
        name!: String = "",
        origin!: String = ""
    ) {
        this.protocolVersion = protocolVersion
        this.method = method
        this.name = name
        this.origin = origin
    }

    public func validateBody(requestMethod: String, requestParams: AgentValue): Result<Unit> {
        if (requestParams.unifiedKind != ValueKind.Object || protocolVersion == "" || method == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.http_header_mismatch",
                "required MCP HTTP request metadata header is missing",
                fields: [ErrorField("json_rpc_code", MCP_HEADER_MISMATCH.toString())]
            ))
        }
        let bodyProtocol = match (requestParams.field("_meta")) {
            case Some(meta) =>
                if (meta.unifiedKind == ValueKind.Object) {
                    match (meta.field(MCP_META_PROTOCOL_VERSION)) {
                        case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else { "" }
                        case None => ""
                    }
                } else { "" }
            case None => ""
        }
        if (bodyProtocol == "" || protocolVersion != bodyProtocol) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.http_header_mismatch",
                "MCP HTTP protocol version header does not match the request body",
                fields: [ErrorField("json_rpc_code", MCP_HEADER_MISMATCH.toString())]
            ))
        }
        if (protocolVersion != MCP_PROTOCOL_VERSION) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.version_unsupported",
                "unsupported MCP protocol version",
                fields: [
                    ErrorField("json_rpc_code", MCP_UNSUPPORTED_PROTOCOL_VERSION.toString()),
                    ErrorField("protocol_version", protocolVersion)
                ]
            ))
        }
        if (method != requestMethod) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.http_header_mismatch",
                "MCP HTTP method header does not match the JSON-RPC body",
                fields: [ErrorField("json_rpc_code", MCP_HEADER_MISMATCH.toString())]
            ))
        }
        if (requestMethod == MCP_METHOD_TOOLS_CALL) {
            let bodyName = match (requestParams.field("name")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else { "" }
                case None => ""
            }
            if (name == "" || name != bodyName) {
                return Result.Err(AgentError(
                    AgentErrorKind.Protocol,
                    "mcp.http_header_mismatch",
                    "MCP HTTP name header does not match tools/call",
                    fields: [ErrorField("json_rpc_code", MCP_HEADER_MISMATCH.toString())]
                ))
            }
        } else if (name != "") {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.http_header_mismatch",
                "MCP HTTP name header is only valid for named operations",
                fields: [ErrorField("json_rpc_code", MCP_HEADER_MISMATCH.toString())]
            ))
        }
        Result.Ok(())
    }
}

public func mcpOriginAllowed(config: McpStreamableHttpServerConfig, origin: String): Bool {
    if (origin == "") { return true }
    for (allowed in config.originAllowlist where allowed == origin) { return true }
    false
}

// Tokens remain transient inputs and are never retained in configuration,
// errors, traces, or model-visible values.
public func mcpBearerAuthorized(authorization: String, expectedToken: String): Bool {
    if (expectedToken == "") { return authorization == "" }
    let prefix = "Bearer "
    if (!authorization.startsWith(prefix)) { return false }
    constantTimeTextEquals(authorization[prefix.size..], expectedToken)
}

public class McpJsonLineFramer {
    private let framing: LineFramer

    public init(config!: McpFramingConfig = McpFramingConfig()) {
        this.framing = LineFramer(maxFrameBytes: config.maxFrameBytes)
    }

    public func push(chunk: String): Result<Array<String>> {
        try {
            Result.Ok(framing.push(chunk))
        } catch (_: ProcessError) {
            Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "mcp.frame_too_large",
                "MCP stdio frame exceeds the configured byte limit"
            ))
        }
    }

    public func bufferedBytes(): Int64 { framing.bufferedBytes() }
}

func secureMcpUrl(value: String): Bool {
    if (value.startsWith("https://")) {
        let authority = mcpUrlAuthority(value, "https://")
        return authority != "" && authority.indexOf("@").isNone() && authority.indexOf(" ").isNone()
    }
    if (!value.startsWith("http://")) { return false }
    loopbackAuthority(mcpUrlAuthority(value, "http://"))
}

func secureMcpOrigin(value: String): Bool {
    let prefix = if (value.startsWith("https://")) {
        "https://"
    } else if (value.startsWith("http://")) {
        "http://"
    } else {
        return false
    }
    let remainder = value[prefix.size..]
    mcpUrlAuthority(value, prefix).size == remainder.size && secureMcpUrl(value)
}

func mcpUrlAuthority(value: String, prefix: String): String {
    let remainder = value[prefix.size..]
    var end = remainder.size
    for (separator in ["/", "?", "#"]) {
        match (remainder.indexOf(separator)) {
            case Some(index) => end = min(end, index)
            case None => ()
        }
    }
    remainder[..end]
}

func loopbackAuthority(authority: String): Bool {
    if (authority == "127.0.0.1" || authority == "localhost" || authority == "[::1]") {
        return true
    }
    for (host in ["127.0.0.1", "localhost", "[::1]"]) {
        let prefix = host + ":"
        if (authority.startsWith(prefix) && asciiDecimal(authority[prefix.size..])) { return true }
    }
    false
}

func asciiDecimal(value: String): Bool {
    if (value == "") { return false }
    for (byte in unsafe { value.rawData() } where !asciiDigit(byte)) { return false }
    true
}

func reservedMcpHttpHeader(value: String): Bool {
    match (value.toAsciiLower()) {
        case "authorization" | "accept" | "content-type" | "origin" |
             "mcp-protocol-version" | "mcp-method" | "mcp-name" => true
        case _ => false
    }
}

func loopbackHost(value: String): Bool {
    value == "127.0.0.1" || value == "localhost" || value == "::1" || value == "[::1]"
}

func validEnvironmentName(value: String): Bool {
    if (value == "") { return false }
    let bytes = unsafe { value.rawData() }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (index == 0) {
            if (!asciiLetter(byte) && byte != b'_') { return false }
        } else if (!asciiLetter(byte) && !asciiDigit(byte) && byte != b'_') {
            return false
        }
    }
    true
}

func validHeaderName(value: String): Bool {
    validMcpHeaderToken(value)
}

func asciiLetter(value: UInt8): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z')
}

func asciiDigit(value: UInt8): Bool {
    value >= b'0' && value <= b'9'
}

func constantTimeTextEquals(left: String, right: String): Bool {
    let leftBytes = unsafe { left.rawData() }
    let rightBytes = unsafe { right.rawData() }
    var difference: Int64 = leftBytes.size ^ rightBytes.size
    let limit = max(leftBytes.size, rightBytes.size)
    for (index in 0..limit) {
        let leftByte: UInt8 = if (index < leftBytes.size) { leftBytes[index] } else { 0 }
        let rightByte: UInt8 = if (index < rightBytes.size) { rightBytes[index] } else { 0 }
        difference = difference | Int64(leftByte ^ rightByte)
    }
    difference == 0
}
