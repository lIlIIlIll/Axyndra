package mcp4cj

import yjson.*
import yjson_support.*
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
public let MCP_NOTIFICATION_PROGRESS = "notifications/progress"
public let MCP_NOTIFICATION_MESSAGE = "notifications/message"
public let MCP_NOTIFICATION_RESOURCES_UPDATED = "notifications/resources/updated"
public let MCP_NOTIFICATION_RESOURCES_LIST_CHANGED = "notifications/resources/list_changed"
public let MCP_NOTIFICATION_TOOLS_LIST_CHANGED = "notifications/tools/list_changed"
public let MCP_NOTIFICATION_PROMPTS_LIST_CHANGED = "notifications/prompts/list_changed"
public let MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED = "notifications/subscriptions/acknowledged"

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

public class McpClientCapabilities {
    public let roots: ?McpCapabilityFeature
    public let sampling: Bool
    public let elicitation: Bool
    public let experimental: JsonNode
    public let extensions: JsonNode

    public init(
        roots!: ?McpCapabilityFeature = None,
        sampling!: Bool = false,
        elicitation!: Bool = false,
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
        if (sampling) { fields.add(JsonObjectEntry("sampling", jsonObject([]))) }
        if (elicitation) { fields.add(JsonObjectEntry("elicitation", jsonObject([]))) }
        if (!experimental.fields.isEmpty()) { fields.add(JsonObjectEntry("experimental", experimental)) }
        appendMcpExtensionFields(fields, extensions)
        jsonObject(fields.toArray())
    }
}

public class McpServerCapabilities2026 {
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
        appendMcpExtensionFields(fields, extensions)
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
        if (fieldName.trimAscii() == "") { throw IllegalArgumentException("MCP page field name must not be empty") }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)))
        fields.add(JsonObjectEntry(fieldName, jsonArray(values)))
        if (nextCursor != "") { fields.add(JsonObjectEntry("nextCursor", jsonString(nextCursor))) }
        fields.add(JsonObjectEntry("ttlMs", jsonNumber(ttlMillis.toString())))
        fields.add(JsonObjectEntry("cacheScope", jsonString(cacheScope)))
        jsonObject(fields.toArray())
    }
}

public enum McpOperationOutcome<T> {
    Complete(T) | InputRequired(McpInputRequiredResult) | Extension(String, JsonNode)
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
