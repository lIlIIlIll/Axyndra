package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import std.collection.*

// MCP 2026-07-28 request and notification names. `ping` is intentionally not
// part of this protocol revision.
public let MCP_METHOD_COMPLETION_COMPLETE = "completion/complete"
public let MCP_METHOD_PROMPTS_LIST = "prompts/list"
public let MCP_METHOD_PROMPTS_GET = "prompts/get"
public let MCP_METHOD_RESOURCES_LIST = "resources/list"
public let MCP_METHOD_RESOURCE_TEMPLATES_LIST = "resources/templates/list"
public let MCP_METHOD_RESOURCES_READ = "resources/read"
public let MCP_METHOD_SUBSCRIPTIONS_LISTEN = "subscriptions/listen"
public let MCP_METHOD_ROOTS_LIST = "roots/list"
public let MCP_METHOD_SAMPLING_CREATE_MESSAGE = "sampling/createMessage"
public let MCP_METHOD_ELICITATION_CREATE = "elicitation/create"
public let MCP_NOTIFICATION_PROGRESS = "notifications/progress"
public let MCP_NOTIFICATION_MESSAGE = "notifications/message"
public let MCP_NOTIFICATION_RESOURCES_UPDATED = "notifications/resources/updated"
public let MCP_NOTIFICATION_RESOURCES_LIST_CHANGED = "notifications/resources/list_changed"
public let MCP_NOTIFICATION_TOOLS_LIST_CHANGED = "notifications/tools/list_changed"
public let MCP_NOTIFICATION_PROMPTS_LIST_CHANGED = "notifications/prompts/list_changed"
public let MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED = "notifications/subscriptions/acknowledged"
public let MCP_META_SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"

// Deprecated client features remain on the 2026-07-28 wire only as typed
// multi-round-trip input requests, not as live reverse transport requests.
public enum McpInputRequest {
    Roots(JsonNode) | Sampling(JsonNode) | Elicitation(JsonNode)

    public func method(): String {
        match (this) {
            case Roots(_) => MCP_METHOD_ROOTS_LIST
            case Sampling(_) => MCP_METHOD_SAMPLING_CREATE_MESSAGE
            case Elicitation(_) => MCP_METHOD_ELICITATION_CREATE
        }
    }
    public func params(): JsonNode {
        match (this) {
            case Roots(value) => value
            case Sampling(value) => value
            case Elicitation(value) => value
        }
    }
    public func toValue(): JsonNode {
        jsonObject([JsonObjectEntry("method", jsonString(method())), JsonObjectEntry("params", params())])
    }
}

public enum McpInputResponse {
    Roots(JsonNode) | Sampling(JsonNode) | Elicitation(JsonNode)

    public func toValue(): JsonNode {
        match (this) {
            case Roots(value) => value
            case Sampling(value) => value
            case Elicitation(value) => value
        }
    }
}

public func decodeMcpInputRequest(value: JsonNode): McpResult<McpInputRequest> {
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpInputRequest>("mcp.input_request_invalid", "MCP input request must be an object")
    }
    let method = mcpText(value, "method")
    let params = match (value.field("params")) {
        case Some(found) => if (found.unifiedKind == UnifiedJsonKind.Object) { found } else {
            return invalidMcp<McpInputRequest>("mcp.input_request_params_invalid", "MCP input request params must be an object")
        }
        case None => if (method == MCP_METHOD_ROOTS_LIST) { jsonObject([]) } else {
            return invalidMcp<McpInputRequest>("mcp.input_request_params_missing", "MCP input request requires params")
        }
    }
    if (method == MCP_METHOD_ROOTS_LIST) { return McpResult.Ok(McpInputRequest.Roots(params)) }
    if (method == MCP_METHOD_SAMPLING_CREATE_MESSAGE) {
        let messages = match (params.field("messages")) {
            case Some(found) => found
            case None => return invalidMcp<McpInputRequest>("mcp.sampling_messages_missing", "sampling/createMessage requires messages")
        }
        if (messages.unifiedKind != UnifiedJsonKind.List || mcpInteger(params, "maxTokens") <= 0) {
            return invalidMcp<McpInputRequest>("mcp.sampling_params_invalid", "sampling/createMessage requires an array of messages and positive maxTokens")
        }
        for (message in messages.items) {
            if (message.unifiedKind != UnifiedJsonKind.Object) {
                return invalidMcp<McpInputRequest>("mcp.sampling_message_invalid", "sampling messages must be objects")
            }
            let role = mcpText(message, "role")
            let content = mcpField(message, "content", jsonNull())
            if ((role != "user" && role != "assistant") || content.unifiedKind != UnifiedJsonKind.Object) {
                return invalidMcp<McpInputRequest>("mcp.sampling_message_invalid", "sampling messages require a valid role and object content")
            }
            if (!validMcpSamplingContent(content)) {
                return invalidMcp<McpInputRequest>("mcp.sampling_message_invalid", "sampling message content is invalid")
            }
        }
        let includeContext = mcpText(params, "includeContext")
        if (includeContext != "" && includeContext != "none" && includeContext != "thisServer" && includeContext != "allServers") {
            return invalidMcp<McpInputRequest>("mcp.sampling_context_invalid", "sampling includeContext is invalid")
        }
        return McpResult.Ok(McpInputRequest.Sampling(params))
    }
    if (method == MCP_METHOD_ELICITATION_CREATE) {
        if (mcpText(params, "message") == "") {
            return invalidMcp<McpInputRequest>("mcp.elicitation_message_missing", "elicitation/create requires a message")
        }
        let mode = mcpText(params, "mode")
        if (mode == "url") {
            if (mcpText(params, "url") == "") {
                return invalidMcp<McpInputRequest>("mcp.elicitation_url_missing", "URL elicitation requires url")
            }
        } else if (mode == "" || mode == "form") {
            let schema = mcpObject(params, "requestedSchema")
            if (!validMcpElicitationSchema(schema)) {
                return invalidMcp<McpInputRequest>("mcp.elicitation_schema_invalid", "form elicitation requires an object requestedSchema")
            }
        } else {
            return invalidMcp<McpInputRequest>("mcp.elicitation_mode_invalid", "elicitation mode is invalid")
        }
        return McpResult.Ok(McpInputRequest.Elicitation(params))
    }
    invalidMcp<McpInputRequest>("mcp.input_request_method_invalid", "unsupported MCP input request method: " + method)
}

func validMcpElicitationSchema(schema: JsonNode): Bool {
    if (schema.unifiedKind != UnifiedJsonKind.Object || mcpText(schema, "type") != "object") {
        return false
    }
    let properties = match (schema.field("properties")) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else { return false }
        case None => return false
    }
    for (property in properties.fields) {
        if (property.value.unifiedKind != UnifiedJsonKind.Object) { return false }
        let kind = mcpText(property.value, "type")
        if (kind != "string" && kind != "number" && kind != "integer" &&
            kind != "boolean" && kind != "array") {
            return false
        }
    }
    match (validateUnifiedJsonSchema(schema, jsonObject([]))) {
        case Some(error) => error.keyword != "schema"
        case None => true
    }
}

func validMcpSamplingContent(content: JsonNode): Bool {
    if (content.unifiedKind != UnifiedJsonKind.Object) { return false }
    match (mcpText(content, "type")) {
        case "text" => match (content.field("text")) {
            case Some(value) => value.unifiedKind == UnifiedJsonKind.Text
            case None => false
        }
        case "image" | "audio" => mcpText(content, "data") != "" && mcpText(content, "mimeType") != ""
        case _ => false
    }
}

public func decodeMcpInputResponse(request: McpInputRequest, value: JsonNode): McpResult<McpInputResponse> {
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpInputResponse>("mcp.input_response_invalid", "MCP input response must be an object")
    }
    match (request) {
        case McpInputRequest.Roots(_) => match (value.field("roots")) {
            case Some(roots) => if (roots.unifiedKind == UnifiedJsonKind.List) {
                for (root in roots.items where root.unifiedKind != UnifiedJsonKind.Object || !mcpText(root, "uri").startsWith("file://")) {
                    return invalidMcp<McpInputResponse>("mcp.roots_result_invalid", "roots/list results require file:// root URIs")
                }
                McpResult.Ok(McpInputResponse.Roots(value))
            } else { invalidMcp<McpInputResponse>("mcp.roots_result_invalid", "roots must be an array") }
            case None => invalidMcp<McpInputResponse>("mcp.roots_result_invalid", "roots/list result requires roots")
        }
        case McpInputRequest.Sampling(_) =>
            if (mcpText(value, "role") == "assistant" &&
                validMcpSamplingContent(mcpField(value, "content", jsonNull())) &&
                mcpText(value, "model") != "") {
                McpResult.Ok(McpInputResponse.Sampling(value))
            } else { invalidMcp<McpInputResponse>("mcp.sampling_result_invalid", "sampling result requires assistant role, content, and model") }
        case McpInputRequest.Elicitation(requestValue) =>
            let action = mcpText(value, "action")
            if (action != "accept" && action != "decline" && action != "cancel") {
                return invalidMcp<McpInputResponse>("mcp.elicitation_result_invalid", "elicitation result action is invalid")
            }
            if (action == "accept" && mcpText(requestValue, "mode") != "url") {
                let content = mcpField(value, "content", jsonNull())
                if (content.unifiedKind != UnifiedJsonKind.Object) {
                    return invalidMcp<McpInputResponse>("mcp.elicitation_content_invalid", "accepted form elicitation requires object content")
                }
                match (validateUnifiedJsonSchema(mcpObject(requestValue, "requestedSchema"), content)) {
                    case Some(error) => return invalidMcp<McpInputResponse>(
                        "mcp.elicitation_content_invalid",
                        "accepted elicitation content violates requestedSchema: " + error.message
                    )
                    case None => ()
                }
            }
            McpResult.Ok(McpInputResponse.Elicitation(value))
    }
}

public class McpSubscriptionFilter {
    public let toolsListChanged: Bool
    public let promptsListChanged: Bool
    public let resourcesListChanged: Bool
    public let resourceSubscriptions: Array<String>
    public let taskIds: Array<String>
    public init(
        toolsListChanged!: Bool = false,
        promptsListChanged!: Bool = false,
        resourcesListChanged!: Bool = false,
        resourceSubscriptions!: Array<String> = [],
        taskIds!: Array<String> = []
    ) {
        for (uri in resourceSubscriptions where uri.trimAscii() == "") {
            throw IllegalArgumentException("MCP resource subscription URI must not be empty")
        }
        for (id in taskIds where id.trimAscii() == "") {
            throw IllegalArgumentException("MCP task subscription ID must not be empty")
        }
        this.toolsListChanged = toolsListChanged; this.promptsListChanged = promptsListChanged
        this.resourcesListChanged = resourcesListChanged
        this.resourceSubscriptions = resourceSubscriptions; this.taskIds = taskIds
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        if (toolsListChanged) { fields.add(JsonObjectEntry("toolsListChanged", jsonBool(true))) }
        if (promptsListChanged) { fields.add(JsonObjectEntry("promptsListChanged", jsonBool(true))) }
        if (resourcesListChanged) { fields.add(JsonObjectEntry("resourcesListChanged", jsonBool(true))) }
        if (!resourceSubscriptions.isEmpty()) {
            let values = ArrayList<JsonNode>(); for (value in resourceSubscriptions) { values.add(jsonString(value)) }
            fields.add(JsonObjectEntry("resourceSubscriptions", jsonArray(values.toArray())))
        }
        if (!taskIds.isEmpty()) {
            let values = ArrayList<JsonNode>(); for (value in taskIds) { values.add(jsonString(value)) }
            fields.add(JsonObjectEntry("taskIds", jsonArray(values.toArray())))
        }
        jsonObject([JsonObjectEntry("notifications", jsonObject(fields.toArray()))])
    }
}

public interface McpSubscriptionSource {
    func acknowledged(): McpSubscriptionFilter
    func next(): McpResult<?JsonRpcNotification>
    func close(): McpResult<Unit>
}

public interface McpSubscriptionHandle {
    func subscriptionId(): JsonRpcId
    func acknowledged(): McpSubscriptionFilter
    func next(): McpResult<?JsonRpcNotification>
    func close(): McpResult<Unit>
}

public class McpCapabilityFeature {
    public let listChanged: Bool
    public let subscribe: Bool
    public let extensions: JsonNode

    public init(
        listChanged!: Bool = false,
        subscribe!: Bool = false,
        extensions!: JsonNode = jsonObject([])
    ) {
        requireObject(extensions, "MCP capability extensions")
        this.listChanged = listChanged
        this.subscribe = subscribe
        this.extensions = extensions
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        if (listChanged) { fields.add(JsonObjectEntry("listChanged", jsonBool(true))) }
        if (subscribe) { fields.add(JsonObjectEntry("subscribe", jsonBool(true))) }
        appendMcpExtensionFields(fields, extensions)
        jsonObject(fields.toArray())
    }
}

public class McpRootsCapability {
    public init() {}
    public func toValue(): JsonNode { jsonObject([]) }
}

public class McpSamplingCapability {
    public let context: Bool
    public let tools: Bool
    public init(context!: Bool = false, tools!: Bool = false) {
        this.context = context; this.tools = tools
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        if (context) { fields.add(JsonObjectEntry("context", jsonObject([]))) }
        if (tools) { fields.add(JsonObjectEntry("tools", jsonObject([]))) }
        jsonObject(fields.toArray())
    }
}

public class McpElicitationCapability {
    public let form: Bool
    public let url: Bool
    public init(form!: Bool = true, url!: Bool = false) { this.form = form; this.url = url }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        if (form) { fields.add(JsonObjectEntry("form", jsonObject([]))) }
        if (url) { fields.add(JsonObjectEntry("url", jsonObject([]))) }
        jsonObject(fields.toArray())
    }
}

public class McpClientCapabilities {
    public let roots: ?McpRootsCapability
    public let sampling: ?McpSamplingCapability
    public let elicitation: ?McpElicitationCapability
    public let experimental: JsonNode
    public let extensions: JsonNode

    public init(
        roots!: ?McpRootsCapability = None,
        sampling!: ?McpSamplingCapability = None,
        elicitation!: ?McpElicitationCapability = None,
        experimental!: JsonNode = jsonObject([]),
        extensions!: JsonNode = jsonObject([])
    ) {
        requireObject(experimental, "MCP experimental client capabilities")
        requireObject(extensions, "MCP client capability extensions")
        this.roots = roots
        this.sampling = sampling
        this.elicitation = elicitation
        this.experimental = experimental
        this.extensions = extensions
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        match (roots) { case Some(value) => fields.add(JsonObjectEntry("roots", value.toValue())); case None => () }
        match (sampling) { case Some(value) => fields.add(JsonObjectEntry("sampling", value.toValue())); case None => () }
        match (elicitation) { case Some(value) => fields.add(JsonObjectEntry("elicitation", value.toValue())); case None => () }
        if (!experimental.fields.isEmpty()) { fields.add(JsonObjectEntry("experimental", experimental)) }
        if (!extensions.fields.isEmpty()) { fields.add(JsonObjectEntry("extensions", extensions)) }
        jsonObject(fields.toArray())
    }
}

public class McpServerCapabilities {
    public let completion: Bool
    public let logging: Bool
    public let prompts: ?McpCapabilityFeature
    public let resources: ?McpCapabilityFeature
    public let tools: ?McpCapabilityFeature
    public let experimental: JsonNode
    public let extensions: JsonNode

    public init(
        completion!: Bool = false,
        logging!: Bool = false,
        prompts!: ?McpCapabilityFeature = None,
        resources!: ?McpCapabilityFeature = None,
        tools!: ?McpCapabilityFeature = None,
        experimental!: JsonNode = jsonObject([]),
        extensions!: JsonNode = jsonObject([])
    ) {
        requireObject(experimental, "MCP experimental server capabilities")
        requireObject(extensions, "MCP server capability extensions")
        this.completion = completion
        this.logging = logging
        this.prompts = prompts
        this.resources = resources
        this.tools = tools
        this.experimental = experimental
        this.extensions = extensions
    }

    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        if (completion) { fields.add(JsonObjectEntry("completions", jsonObject([]))) }
        if (logging) { fields.add(JsonObjectEntry("logging", jsonObject([]))) }
        match (prompts) { case Some(value) => fields.add(JsonObjectEntry("prompts", value.toValue())); case None => () }
        match (resources) { case Some(value) => fields.add(JsonObjectEntry("resources", value.toValue())); case None => () }
        match (tools) { case Some(value) => fields.add(JsonObjectEntry("tools", value.toValue())); case None => () }
        if (!experimental.fields.isEmpty()) { fields.add(JsonObjectEntry("experimental", experimental)) }
        if (!extensions.fields.isEmpty()) { fields.add(JsonObjectEntry("extensions", extensions)) }
        jsonObject(fields.toArray())
    }
}

public class McpPromptArgument {
    public let name: String
    public let description: String
    public let required: Bool
    public init(name: String, description!: String = "", required!: Bool = false) {
        if (name.trimAscii() == "") { throw IllegalArgumentException("MCP prompt argument name must not be empty") }
        this.name = name; this.description = description; this.required = required
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("name", jsonString(name)))
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        if (required) { fields.add(JsonObjectEntry("required", jsonBool(true))) }
        jsonObject(fields.toArray())
    }
}

public class McpPrompt {
    public let name: String
    public let title: String
    public let description: String
    public let arguments: Array<McpPromptArgument>
    public let meta: JsonNode
    public init(
        name: String,
        title!: String = "",
        description!: String = "",
        arguments!: Array<McpPromptArgument> = [],
        meta!: JsonNode = jsonObject([])
    ) {
        if (name.trimAscii() == "") { throw IllegalArgumentException("MCP prompt name must not be empty") }
        requireObject(meta, "MCP prompt metadata")
        this.name = name; this.title = title; this.description = description; this.arguments = arguments; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>(); let args = ArrayList<JsonNode>()
        fields.add(JsonObjectEntry("name", jsonString(name)))
        if (title != "") { fields.add(JsonObjectEntry("title", jsonString(title))) }
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        for (argument in arguments) { args.add(argument.toValue()) }
        if (!args.isEmpty()) { fields.add(JsonObjectEntry("arguments", jsonArray(args.toArray()))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpResource {
    public let uri: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String
    public let size: ?Int64
    public let annotations: JsonNode
    public let meta: JsonNode
    public init(
        uri: String,
        name: String,
        title!: String = "",
        description!: String = "",
        mimeType!: String = "",
        size!: ?Int64 = None,
        annotations!: JsonNode = jsonObject([]),
        meta!: JsonNode = jsonObject([])
    ) {
        if (uri.trimAscii() == "" || name.trimAscii() == "") { throw IllegalArgumentException("MCP resource uri and name must not be empty") }
        match (size) { case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP resource size must not be negative") }; case None => () }
        requireObject(annotations, "MCP resource annotations"); requireObject(meta, "MCP resource metadata")
        this.uri = uri; this.name = name; this.title = title; this.description = description
        this.mimeType = mimeType; this.size = size; this.annotations = annotations; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("uri", jsonString(uri))); fields.add(JsonObjectEntry("name", jsonString(name)))
        if (title != "") { fields.add(JsonObjectEntry("title", jsonString(title))) }
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        if (mimeType != "") { fields.add(JsonObjectEntry("mimeType", jsonString(mimeType))) }
        match (size) { case Some(value) => fields.add(JsonObjectEntry("size", jsonNumber(value.toString()))); case None => () }
        if (!annotations.fields.isEmpty()) { fields.add(JsonObjectEntry("annotations", annotations)) }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpResourceTemplate {
    public let uriTemplate: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String
    public let annotations: JsonNode
    public let meta: JsonNode
    public init(
        uriTemplate: String,
        name: String,
        title!: String = "",
        description!: String = "",
        mimeType!: String = "",
        annotations!: JsonNode = jsonObject([]),
        meta!: JsonNode = jsonObject([])
    ) {
        if (uriTemplate.trimAscii() == "" || name.trimAscii() == "") { throw IllegalArgumentException("MCP resource template and name must not be empty") }
        requireObject(annotations, "MCP resource template annotations"); requireObject(meta, "MCP resource template metadata")
        this.uriTemplate = uriTemplate; this.name = name; this.title = title; this.description = description
        this.mimeType = mimeType; this.annotations = annotations; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("uriTemplate", jsonString(uriTemplate))); fields.add(JsonObjectEntry("name", jsonString(name)))
        if (title != "") { fields.add(JsonObjectEntry("title", jsonString(title))) }
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        if (mimeType != "") { fields.add(JsonObjectEntry("mimeType", jsonString(mimeType))) }
        if (!annotations.fields.isEmpty()) { fields.add(JsonObjectEntry("annotations", annotations)) }
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpPage {
    public let values: Array<JsonNode>
    public let nextCursor: String
    public let ttlMillis: Int64
    public let cacheScope: String
    public init(values: Array<JsonNode>, nextCursor!: String = "", ttlMillis!: Int64 = 300000, cacheScope!: String = "private") {
        if (ttlMillis < 0 || !validMcpCacheScope(cacheScope)) { throw IllegalArgumentException("invalid MCP page cache metadata") }
        this.values = values; this.nextCursor = nextCursor; this.ttlMillis = ttlMillis; this.cacheScope = cacheScope
    }
    public func toValue(fieldName: String): JsonNode {
        if (fieldName.trimAscii() == "" || fieldName == "resultType" || fieldName == "nextCursor" ||
            fieldName == "ttlMs" || fieldName == "cacheScope") {
            throw IllegalArgumentException("MCP page field name must not be empty or reserved")
        }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry(fieldName, jsonArray(values)))
        if (nextCursor != "") { fields.add(JsonObjectEntry("nextCursor", jsonString(nextCursor))) }
        fields.add(JsonObjectEntry("ttlMs", jsonNumber(ttlMillis.toString())))
        fields.add(JsonObjectEntry("cacheScope", jsonString(cacheScope)))
        jsonObject(fields.toArray())
    }
}

public class McpCompletionResult {
    public let completion: JsonNode
    public let meta: JsonNode
    public init(completion: JsonNode, meta!: JsonNode = jsonObject([])) {
        requireObject(completion, "MCP completion")
        requireObject(meta, "MCP completion metadata")
        this.completion = completion; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry("completion", completion))
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpPromptResult {
    public let description: String
    public let messages: Array<JsonNode>
    public let meta: JsonNode
    public init(messages: Array<JsonNode>, description!: String = "", meta!: JsonNode = jsonObject([])) {
        for (message in messages where message.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("MCP prompt messages must be objects")
        }
        requireObject(meta, "MCP prompt result metadata")
        this.description = description; this.messages = messages; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        if (description != "") { fields.add(JsonObjectEntry("description", jsonString(description))) }
        fields.add(JsonObjectEntry("messages", jsonArray(messages)))
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public class McpReadResourceResult {
    public let contents: Array<JsonNode>
    public let ttlMillis: Int64
    public let cacheScope: String
    public let meta: JsonNode
    public init(
        contents: Array<JsonNode>, ttlMillis!: Int64 = 300000,
        cacheScope!: String = "private", meta!: JsonNode = jsonObject([])
    ) {
        for (content in contents where content.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("MCP resource contents must be objects")
        }
        if (ttlMillis < 0 || !validMcpCacheScope(cacheScope)) {
            throw IllegalArgumentException("invalid MCP resource cache metadata")
        }
        requireObject(meta, "MCP resource result metadata")
        this.contents = contents; this.ttlMillis = ttlMillis; this.cacheScope = cacheScope; this.meta = meta
    }
    public func toValue(): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry("contents", jsonArray(contents)))
        fields.add(JsonObjectEntry("ttlMs", jsonNumber(ttlMillis.toString())))
        fields.add(JsonObjectEntry("cacheScope", jsonString(cacheScope)))
        if (!meta.fields.isEmpty()) { fields.add(JsonObjectEntry("_meta", meta)) }
        jsonObject(fields.toArray())
    }
}

public enum McpOperationOutcome<T> {
    Complete(T) | InputRequired(McpInputRequiredResult) | Task(McpTask) | Extension(String, JsonNode)
}

public func mcpOperationOutcomeValue<T>(
    outcome: McpOperationOutcome<T>, encode: (T) -> JsonNode
): JsonNode {
    match (outcome) {
        case McpOperationOutcome.Complete(value) => encode(value)
        case McpOperationOutcome.InputRequired(value) => value.toValue()
        case McpOperationOutcome.Task(value) => value.toValue(resultType: MCP_RESULT_TASK)
        case McpOperationOutcome.Extension(resultType, value) => mcpExtensionOutcomeValue(resultType, value)
    }
}

func mcpExtensionOutcomeValue(resultType: String, value: JsonNode): JsonNode {
    requireObject(value, "MCP extension result")
    if (resultType.trimAscii() == "" || resultType == MCP_RESULT_COMPLETE ||
        resultType == MCP_RESULT_INPUT_REQUIRED || resultType == MCP_RESULT_TASK) {
        throw IllegalArgumentException("MCP extension resultType must be non-empty and non-core")
    }
    let fields = ArrayList<JsonObjectEntry>()
    fields.add(JsonObjectEntry("resultType", jsonString(resultType)))
    for (field in value.fields where field.name != "resultType") { fields.add(field) }
    jsonObject(fields.toArray())
}

public interface McpInputResolver {
    func resolve(requests: JsonNode, requestState: String): McpResult<JsonNode>
}

public class McpResolutionPolicy {
    public let maxRounds: Int64
    public init(maxRounds!: Int64 = 10) {
        if (maxRounds <= 0 || maxRounds > 10) { throw IllegalArgumentException("MCP input resolution maxRounds must be in 1..10") }
        this.maxRounds = maxRounds
    }
}

func appendMcpExtensionFields(fields: ArrayList<JsonObjectEntry>, extensions: JsonNode): Unit {
    for (extension in extensions.fields) {
        var duplicate = false
        for (field in fields where field.name == extension.name) { duplicate = true; break }
        if (!duplicate) { fields.add(extension) }
    }
}
