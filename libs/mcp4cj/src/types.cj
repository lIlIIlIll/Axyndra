package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import std.collection.*
import std.sync.*

public let MCP_PROTOCOL_VERSION = "2026-07-28"
public let MCP_HEADER_PROTOCOL_VERSION = "MCP-Protocol-Version"
public let MCP_HEADER_METHOD = "Mcp-Method"
public let MCP_HEADER_NAME = "Mcp-Name"
public let MCP_HEADER_CLIENT_INSTANCE_ID = "Mcp-Client-Instance-Id"
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
public let MCP_METHOD_TOOLS_LIST = "tools/list"
public let MCP_METHOD_TOOLS_CALL = "tools/call"
public let MCP_METHOD_CANCELLED = "notifications/cancelled"

public enum McpTaskSupport <: Equatable<McpTaskSupport> {
    Forbidden | Optional | Required

    public operator func ==(other: McpTaskSupport): Bool {
        match (this) {
            case Forbidden => if (let Forbidden <- other) { true } else { false }
            case Optional => if (let Optional <- other) { true } else { false }
            case Required => if (let Required <- other) { true } else { false }
        }
    }
    public operator func !=(other: McpTaskSupport): Bool { !(this == other) }
}

public class McpToolExecution {
    public let taskSupport: McpTaskSupport
    public init(taskSupport!: McpTaskSupport = McpTaskSupport.Forbidden) {
        this.taskSupport = taskSupport
    }
    public func toValue(): JsonNode {
        jsonObject([JsonObjectEntry("taskSupport", jsonString(match (taskSupport) {
            case McpTaskSupport.Forbidden => "forbidden"
            case McpTaskSupport.Optional => "optional"
            case McpTaskSupport.Required => "required"
        }))])
    }
}

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
    public let data: JsonNode

    public init(
        kind: McpErrorKind,
        code: String,
        message: String,
        retryable!: Bool = false,
        retrySafe!: Bool = false,
        rpcCode!: ?Int64 = None,
        httpStatus!: ?Int64 = None,
        remoteCode!: String = "",
        data!: JsonNode = jsonNull()
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

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("name", jsonString(name)))
        fields.add(JsonObjectEntry("version", jsonString(version)))
        if (title != "") { fields.add(JsonObjectEntry("title", jsonString(title))) }
        jsonObject(fields.toArray())
    }
}

public class McpRequestMeta {
    public let protocolVersion: String
    public let clientInfo: ?McpImplementationInfo
    public let clientCapabilities: McpClientCapabilities

    public init(
        clientInfo!: ?McpImplementationInfo = None,
        clientCapabilities!: McpClientCapabilities = McpClientCapabilities(),
        protocolVersion!: String = MCP_PROTOCOL_VERSION
    ) {
        if (protocolVersion != MCP_PROTOCOL_VERSION) {
            throw IllegalArgumentException("unsupported MCP protocol version")
        }
        this.protocolVersion = protocolVersion
        this.clientInfo = clientInfo
        this.clientCapabilities = clientCapabilities
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry(MCP_META_PROTOCOL_VERSION, jsonString(protocolVersion)))
        match (clientInfo) {
            case Some(value) => fields.add(JsonObjectEntry(MCP_META_CLIENT_INFO, value.toValue()))
            case None => ()
        }
        fields.add(JsonObjectEntry(MCP_META_CLIENT_CAPABILITIES, clientCapabilities.toValue()))
        jsonObject(fields.toArray())
    }
}

public class McpDiscoverResult {
    public let supportedVersions: Array<String>
    public let serverInfo: ?McpImplementationInfo
    public let capabilities: McpServerCapabilities
    public let instructions: String
    public let ttlMillis: Int64
    public let cacheScope: String

    public init(
        serverInfo!: ?McpImplementationInfo = None,
        capabilities!: McpServerCapabilities = McpServerCapabilities(
            tools: Some(McpCapabilityFeature())
        ),
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

    public func toValue(): JsonNode {
        let versions = ArrayList<JsonNode>()
        for (version in supportedVersions) { versions.add(jsonString(version)) }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry("supportedVersions", jsonArray(versions.toArray())))
        fields.add(JsonObjectEntry("capabilities", capabilities.toValue()))
        fields.add(JsonObjectEntry("ttlMs", jsonNumber(ttlMillis.toString())))
        fields.add(JsonObjectEntry("cacheScope", jsonString(cacheScope)))
        if (instructions != "") { fields.add(JsonObjectEntry("instructions", jsonString(instructions))) }
        jsonObject(fields.toArray())
    }
}

public class McpTool {
    public let name: String
    public let description: String
    public let inputSchema: JsonNode
    public let outputSchema: JsonNode
    public let annotations: JsonNode
    public let execution: ?McpToolExecution
    public let meta: JsonNode

    public init(
        name: String,
        description: String,
        inputSchema: JsonNode,
        outputSchema!: JsonNode = jsonNull(),
        annotations!: JsonNode = jsonObject([]),
        execution!: ?McpToolExecution = None,
        meta!: JsonNode = jsonObject([])
    ) {
        if (name.trimAscii() == "") { throw IllegalArgumentException("MCP tool name must not be empty") }
        if (inputSchema.unifiedKind != UnifiedJsonKind.Object || textField(inputSchema, "type") != "object") {
            throw IllegalArgumentException("MCP tool input schema root type must be object")
        }
        if (outputSchema.unifiedKind != UnifiedJsonKind.Null && outputSchema.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("MCP tool output schema must be an object or null")
        }
        requireObject(annotations, "MCP tool annotations")
        requireObject(meta, "MCP tool metadata")
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
        this.outputSchema = outputSchema
        this.annotations = annotations
        this.execution = execution
        this.meta = meta
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("name", jsonString(name)))
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        fields.add(JsonObjectEntry("inputSchema", inputSchema))
        if (outputSchema.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("outputSchema", outputSchema)) }
        if (!annotations.fields.isEmpty()) { fields.add(JsonObjectEntry("annotations", annotations)) }
        match (execution) {
            case Some(value) => fields.add(JsonObjectEntry("execution", value.toValue()))
            case None => ()
        }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
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

    public func toValue(): JsonNode {
        let values = ArrayList<JsonNode>()
        for (tool in tools) { values.add(tool.toValue()) }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry("tools", jsonArray(values.toArray())))
        if (nextCursor != "") { fields.add(JsonObjectEntry("nextCursor", jsonString(nextCursor))) }
        fields.add(JsonObjectEntry("ttlMs", jsonNumber(ttlMillis.toString())))
        fields.add(JsonObjectEntry("cacheScope", jsonString(cacheScope)))
        jsonObject(fields.toArray())
    }
}

public class McpCallToolResult {
    public let content: Array<JsonNode>
    public let structuredContent: JsonNode
    public let isError: Bool
    public let meta: JsonNode

    public init(
        content: Array<JsonNode>,
        structuredContent!: JsonNode = jsonNull(),
        isError!: Bool = false,
        meta!: JsonNode = jsonObject([])
    ) {
        for (block in content where block.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("MCP content blocks must be objects")
        }
        requireObject(meta, "MCP result metadata")
        this.content = content
        this.structuredContent = structuredContent
        this.isError = isError
        this.meta = meta
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry("content", jsonArray(content)))
        if (structuredContent.unifiedKind != UnifiedJsonKind.Null) {
            fields.add(JsonObjectEntry("structuredContent", structuredContent))
        }
        if (isError) { fields.add(JsonObjectEntry("isError", jsonBool(true))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpInputRequiredResult {
    public let inputRequests: JsonNode
    public let requestState: String
    public let meta: JsonNode

    public init(
        inputRequests!: JsonNode = jsonObject([]),
        requestState!: String = "",
        meta!: JsonNode = jsonObject([])
    ) {
        requireObject(inputRequests, "MCP MRTR requests")
        requireObject(meta, "MCP MRTR metadata")
        if (inputRequests.fields.isEmpty() && requestState == "") {
            throw IllegalArgumentException("MCP input_required requires inputRequests or requestState")
        }
        for (field in inputRequests.fields) {
            match (decodeMcpInputRequest(field.value)) {
                case McpResult.Ok(_) => ()
                case McpResult.Err(error) => throw IllegalArgumentException(error.message)
            }
        }
        this.inputRequests = inputRequests
        this.requestState = requestState
        this.meta = meta
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_INPUT_REQUIRED)))
        if (!inputRequests.fields.isEmpty()) { fields.add(JsonObjectEntry("inputRequests", inputRequests)) }
        if (requestState != "") { fields.add(JsonObjectEntry("requestState", jsonString(requestState))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpToolCallContinuation {
    public let inputResponses: JsonNode
    public let requestState: String
    public let tasksSupported: Bool
    private let progressToken: JsonNode
    private let notificationSink: (JsonRpcNotification) -> Unit
    public init(
        inputResponses!: JsonNode = jsonObject([]),
        requestState!: String = "",
        tasksSupported!: Bool = false,
        progressToken!: JsonNode = jsonNull(),
        notificationSink!: (JsonRpcNotification) -> Unit = { _ => }
    ) {
        requireObject(inputResponses, "MCP MRTR inputResponses")
        for (field in inputResponses.fields where field.value.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("MCP input response entries must be result objects")
        }
        this.inputResponses = inputResponses
        this.requestState = requestState
        this.tasksSupported = tasksSupported
        this.progressToken = progressToken
        this.notificationSink = notificationSink
    }
    public func isRetry(): Bool { !inputResponses.fields.isEmpty() || requestState != "" }
    public func hasProgressToken(): Bool { progressToken.unifiedKind != UnifiedJsonKind.Null }
    func requestProgressToken(): JsonNode { progressToken }
    public func reportProgress(progress: Float64, total!: ?Float64 = None, message!: String = ""): Unit {
        if (!hasProgressToken()) { return }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("progressToken", progressToken))
        fields.add(JsonObjectEntry("progress", jsonNumber(progress.toString())))
        match (total) { case Some(value) => fields.add(JsonObjectEntry("total", jsonNumber(value.toString()))); case None => () }
        if (message != "") { fields.add(JsonObjectEntry("message", jsonString(message))) }
        notificationSink(JsonRpcNotification("notifications/progress", params: jsonObject(fields.toArray())))
    }
}

public type McpCallToolOutcome = McpOperationOutcome<McpCallToolResult>

public func mcpCallToolOutcomeValue(outcome: McpCallToolOutcome): JsonNode {
    match (outcome) {
        case McpCallToolOutcome.Complete(value) => value.toValue()
        case McpCallToolOutcome.InputRequired(value) => value.toValue()
        case McpCallToolOutcome.Task(value) => value.toValue(resultType: MCP_RESULT_TASK)
        case McpCallToolOutcome.Extension(resultType, value) => mcpExtensionOutcomeValue(resultType, value)
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

func textField(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func requireObject(value: JsonNode, name: String): Unit {
    if (value.unifiedKind != UnifiedJsonKind.Object) { throw IllegalArgumentException(name + " must be an object") }
}
