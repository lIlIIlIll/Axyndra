package mcp4cj

import json4cj.*
import std.collection.*
import std.sync.*

public let MCP_PROTOCOL_VERSION = "2026-07-28"
public let MCP_HEADER_PROTOCOL_VERSION = "MCP-Protocol-Version"
public let MCP_HEADER_METHOD = "Mcp-Method"
public let MCP_HEADER_NAME = "Mcp-Name"
public let MCP_HEADER_PARAM_PREFIX = "Mcp-Param-"
public let MCP_META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
public let MCP_META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
public let MCP_META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
public let MCP_META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
public let MCP_HEADER_MISMATCH: Int64 = -32020
public let MCP_MISSING_REQUIRED_CLIENT_CAPABILITY: Int64 = -32021
public let MCP_UNSUPPORTED_PROTOCOL_VERSION: Int64 = -32022
public let MCP_RESULT_COMPLETE = "complete"
public let MCP_RESULT_INPUT_REQUIRED = "input_required"
public let MCP_METHOD_DISCOVER = "server/discover"
public let MCP_METHOD_PING = "ping"
public let MCP_METHOD_TOOLS_LIST = "tools/list"
public let MCP_METHOD_TOOLS_CALL = "tools/call"
public let MCP_METHOD_CANCELLED = "notifications/cancelled"

public enum McpErrorKind <: Equatable<McpErrorKind> {
    Protocol | Transport | Lifecycle | Authentication | Authorization | Remote | Cancelled | Deadline

    public operator func ==(other: McpErrorKind): Bool {
        match (this) {
            case Protocol => if (let Protocol <- other) { true } else { false }
            case Transport => if (let Transport <- other) { true } else { false }
            case Lifecycle => if (let Lifecycle <- other) { true } else { false }
            case Authentication => if (let Authentication <- other) { true } else { false }
            case Authorization => if (let Authorization <- other) { true } else { false }
            case Remote => if (let Remote <- other) { true } else { false }
            case Cancelled => if (let Cancelled <- other) { true } else { false }
            case Deadline => if (let Deadline <- other) { true } else { false }
        }
    }
    public operator func !=(other: McpErrorKind): Bool { !(this == other) }
}

public class McpError <: Exception {
    public let kind: McpErrorKind
    public let code: String
    public let retryable: Bool
    public let retrySafe: Bool
    public let rpcCode: ?Int64
    public let httpStatus: ?Int64
    public let remoteCode: String
    public let data: JsonValue

    public init(
        kind: McpErrorKind,
        code: String,
        message: String,
        retryable!: Bool = false,
        retrySafe!: Bool = false,
        rpcCode!: ?Int64 = None,
        httpStatus!: ?Int64 = None,
        remoteCode!: String = "",
        data!: JsonValue = JsonValue.nullValue()
    ) {
        super(message)
        this.kind = kind
        this.code = code
        this.retryable = retryable
        this.retrySafe = retrySafe
        this.rpcCode = rpcCode
        this.httpStatus = httpStatus
        this.remoteCode = remoteCode
        this.data = data
    }
}

public class McpImplementationInfo {
    public let name: String
    public let version: String
    public let title: String

    public init(name: String, version: String, title!: String = "") {
        if (name.trimAscii() == "" || version.trimAscii() == "") {
            throw IllegalArgumentException("MCP implementation name and version must not be empty")
        }
        this.name = name
        this.version = version
        this.title = title.trimAscii()
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("name", JsonValue.stringValue(name)))
        fields.add(JsonField("version", JsonValue.stringValue(version)))
        if (title != "") { fields.add(JsonField("title", JsonValue.stringValue(title))) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpRequestMeta {
    public let protocolVersion: String
    public let clientInfo: McpImplementationInfo
    public let clientCapabilities: JsonValue

    public init(
        clientInfo: McpImplementationInfo,
        clientCapabilities!: JsonValue = JsonValue.objectValue([]),
        protocolVersion!: String = MCP_PROTOCOL_VERSION
    ) {
        if (protocolVersion != MCP_PROTOCOL_VERSION) {
            throw IllegalArgumentException("unsupported MCP protocol version")
        }
        requireObject(clientCapabilities, "MCP client capabilities")
        this.protocolVersion = protocolVersion
        this.clientInfo = clientInfo
        this.clientCapabilities = clientCapabilities
    }

    public func toValue(): JsonValue {
        JsonValue.objectValue([
            JsonField(MCP_META_PROTOCOL_VERSION, JsonValue.stringValue(protocolVersion)),
            JsonField(MCP_META_CLIENT_INFO, clientInfo.toValue()),
            JsonField(MCP_META_CLIENT_CAPABILITIES, clientCapabilities)
        ])
    }
}

public class McpServerCapabilities {
    public let tools: Bool
    public let toolListChanged: Bool
    public init(tools!: Bool = true, toolListChanged!: Bool = false) {
        this.tools = tools
        this.toolListChanged = toolListChanged
    }
    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        if (tools) {
            fields.add(JsonField("tools", JsonValue.objectValue([
                JsonField("listChanged", JsonValue.boolValue(toolListChanged))
            ])))
        }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpDiscoverResult {
    public let supportedVersions: Array<String>
    public let serverInfo: McpImplementationInfo
    public let capabilities: McpServerCapabilities
    public let instructions: String
    public let ttlMillis: Int64
    public let cacheScope: String

    public init(
        serverInfo: McpImplementationInfo,
        capabilities!: McpServerCapabilities = McpServerCapabilities(),
        instructions!: String = "",
        supportedVersions!: Array<String> = [MCP_PROTOCOL_VERSION],
        ttlMillis!: Int64 = 300000,
        cacheScope!: String = "private"
    ) {
        var current = false
        for (version in supportedVersions where version == MCP_PROTOCOL_VERSION) { current = true }
        if (supportedVersions.isEmpty() || !current || ttlMillis < 0 || !validMcpCacheScope(cacheScope)) {
            throw IllegalArgumentException("invalid MCP discovery version or cache metadata")
        }
        this.supportedVersions = supportedVersions
        this.serverInfo = serverInfo
        this.capabilities = capabilities
        this.instructions = instructions
        this.ttlMillis = ttlMillis
        this.cacheScope = cacheScope
    }

    public func toValue(): JsonValue {
        let versions = ArrayList<JsonValue>()
        for (version in supportedVersions) { versions.add(JsonValue.stringValue(version)) }
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("resultType", JsonValue.stringValue(MCP_RESULT_COMPLETE)))
        fields.add(JsonField("supportedVersions", JsonValue.arrayValue(versions.toArray())))
        fields.add(JsonField("capabilities", capabilities.toValue()))
        fields.add(JsonField("ttlMs", JsonValue.numberValue(ttlMillis.toString())))
        fields.add(JsonField("cacheScope", JsonValue.stringValue(cacheScope)))
        if (instructions != "") { fields.add(JsonField("instructions", JsonValue.stringValue(instructions))) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpTool {
    public let name: String
    public let description: String
    public let inputSchema: JsonValue
    public let outputSchema: JsonValue
    public let annotations: JsonValue
    public let meta: JsonValue

    public init(
        name: String,
        description: String,
        inputSchema: JsonValue,
        outputSchema!: JsonValue = JsonValue.nullValue(),
        annotations!: JsonValue = JsonValue.objectValue([]),
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        if (name.trimAscii() == "") { throw IllegalArgumentException("MCP tool name must not be empty") }
        if (inputSchema.kind != JsonKind.Object || textField(inputSchema, "type") != "object") {
            throw IllegalArgumentException("MCP tool input schema root type must be object")
        }
        if (outputSchema.kind != JsonKind.Null && outputSchema.kind != JsonKind.Object) {
            throw IllegalArgumentException("MCP tool output schema must be an object or null")
        }
        requireObject(annotations, "MCP tool annotations")
        requireObject(meta, "MCP tool metadata")
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
        this.outputSchema = outputSchema
        this.annotations = annotations
        this.meta = meta
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("name", JsonValue.stringValue(name)))
        if (description != "") { fields.add(JsonField("description", JsonValue.stringValue(description))) }
        fields.add(JsonField("inputSchema", inputSchema))
        if (outputSchema.kind != JsonKind.Null) { fields.add(JsonField("outputSchema", outputSchema)) }
        if (!annotations.fields.isEmpty()) { fields.add(JsonField("annotations", annotations)) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpToolListPage {
    public let tools: Array<McpTool>
    public let nextCursor: String
    public let ttlMillis: Int64
    public let cacheScope: String

    public init(
        tools: Array<McpTool>,
        nextCursor!: String = "",
        ttlMillis!: Int64 = 300000,
        cacheScope!: String = "private"
    ) {
        if (ttlMillis < 0 || !validMcpCacheScope(cacheScope)) {
            throw IllegalArgumentException("invalid MCP tool directory cache metadata")
        }
        this.tools = tools
        this.nextCursor = nextCursor
        this.ttlMillis = ttlMillis
        this.cacheScope = cacheScope
    }

    public func toValue(): JsonValue {
        let values = ArrayList<JsonValue>()
        for (tool in tools) { values.add(tool.toValue()) }
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("resultType", JsonValue.stringValue(MCP_RESULT_COMPLETE)))
        fields.add(JsonField("tools", JsonValue.arrayValue(values.toArray())))
        if (nextCursor != "") { fields.add(JsonField("nextCursor", JsonValue.stringValue(nextCursor))) }
        fields.add(JsonField("ttlMs", JsonValue.numberValue(ttlMillis.toString())))
        fields.add(JsonField("cacheScope", JsonValue.stringValue(cacheScope)))
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpCallToolResult {
    public let content: Array<JsonValue>
    public let structuredContent: JsonValue
    public let isError: Bool
    public let meta: JsonValue

    public init(
        content: Array<JsonValue>,
        structuredContent!: JsonValue = JsonValue.nullValue(),
        isError!: Bool = false,
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        for (block in content where block.kind != JsonKind.Object) {
            throw IllegalArgumentException("MCP content blocks must be objects")
        }
        requireObject(meta, "MCP result metadata")
        this.content = content
        this.structuredContent = structuredContent
        this.isError = isError
        this.meta = meta
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("resultType", JsonValue.stringValue(MCP_RESULT_COMPLETE)))
        fields.add(JsonField("content", JsonValue.arrayValue(content)))
        if (structuredContent.kind != JsonKind.Null) {
            fields.add(JsonField("structuredContent", structuredContent))
        }
        if (isError) { fields.add(JsonField("isError", JsonValue.boolValue(true))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpInputRequiredResult {
    public let inputRequests: JsonValue
    public let requestState: String
    public let meta: JsonValue

    public init(
        inputRequests!: JsonValue = JsonValue.objectValue([]),
        requestState!: String = "",
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        requireObject(inputRequests, "MCP MRTR requests")
        requireObject(meta, "MCP MRTR metadata")
        if (inputRequests.fields.isEmpty() && requestState == "") {
            throw IllegalArgumentException("MCP input_required requires inputRequests or requestState")
        }
        for (field in inputRequests.fields where field.value.kind != JsonKind.Object) {
            throw IllegalArgumentException("MCP input request entries must be request objects")
        }
        this.inputRequests = inputRequests
        this.requestState = requestState
        this.meta = meta
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("resultType", JsonValue.stringValue(MCP_RESULT_INPUT_REQUIRED)))
        if (!inputRequests.fields.isEmpty()) { fields.add(JsonField("inputRequests", inputRequests)) }
        if (requestState != "") { fields.add(JsonField("requestState", JsonValue.stringValue(requestState))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpToolCallContinuation {
    public let inputResponses: JsonValue
    public let requestState: String
    public init(
        inputResponses!: JsonValue = JsonValue.objectValue([]),
        requestState!: String = ""
    ) {
        requireObject(inputResponses, "MCP MRTR inputResponses")
        for (field in inputResponses.fields where field.value.kind != JsonKind.Object) {
            throw IllegalArgumentException("MCP input response entries must be result objects")
        }
        this.inputResponses = inputResponses
        this.requestState = requestState
    }
    public func isRetry(): Bool { !inputResponses.fields.isEmpty() || requestState != "" }
}

public enum McpCallToolOutcome {
    Complete(McpCallToolResult) | InputRequired(McpInputRequiredResult)
}

public func mcpCallToolOutcomeValue(outcome: McpCallToolOutcome): JsonValue {
    match (outcome) {
        case McpCallToolOutcome.Complete(value) => value.toValue()
        case McpCallToolOutcome.InputRequired(value) => value.toValue()
    }
}

public class McpToolDirectorySnapshot {
    public let tools: Array<McpTool>
    public let observedAtMillis: Int64
    public let ttlMillis: Int64
    public let cacheScope: String
    public init(page: McpToolListPage, observedAtMillis: Int64) {
        if (page.nextCursor != "") {
            throw IllegalArgumentException("directory snapshot requires the final MCP tool page")
        }
        this.tools = page.tools
        this.observedAtMillis = observedAtMillis
        this.ttlMillis = page.ttlMillis
        this.cacheScope = page.cacheScope
    }
    public func isFresh(nowMillis: Int64): Bool {
        nowMillis >= observedAtMillis && nowMillis - observedAtMillis <= ttlMillis
    }
}

public class McpToolDirectoryCache {
    private let lock = Mutex()
    private var snapshot: ?McpToolDirectorySnapshot = None
    public init() {}
    public func store(value: McpToolDirectorySnapshot): Unit {
        lock.lock(); try { snapshot = Some(value) } finally { lock.unlock() }
    }
    public func fresh(nowMillis: Int64): ?McpToolDirectorySnapshot {
        lock.lock()
        try {
            match (snapshot) {
                case Some(value) => if (value.isFresh(nowMillis)) { Some(value) } else { None }
                case None => None
            }
        } finally { lock.unlock() }
    }
    public func invalidate(): Unit {
        lock.lock(); try { snapshot = None } finally { lock.unlock() }
    }
}

public func validMcpCacheScope(value: String): Bool { value == "public" || value == "private" }

func textField(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.kind == JsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func requireObject(value: JsonValue, name: String): Unit {
    if (value.kind != JsonKind.Object) { throw IllegalArgumentException(name + " must be an object") }
}
