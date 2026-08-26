package mcp4cj

import json4cj.*
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
    public let extensions: JsonValue

    public init(
        listChanged!: Bool = false,
        subscribe!: Bool = false,
        extensions!: JsonValue = JsonValue.objectValue([])
    ) {
        requireObject(extensions, "MCP capability extensions")
        this.listChanged = listChanged
        this.subscribe = subscribe
        this.extensions = extensions
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        if (listChanged) { fields.add(JsonField("listChanged", JsonValue.boolValue(true))) }
        if (subscribe) { fields.add(JsonField("subscribe", JsonValue.boolValue(true))) }
        appendMcpExtensionFields(fields, extensions)
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpClientCapabilities {
    public let roots: ?McpCapabilityFeature
    public let sampling: Bool
    public let elicitation: Bool
    public let experimental: JsonValue
    public let extensions: JsonValue

    public init(
        roots!: ?McpCapabilityFeature = None,
        sampling!: Bool = false,
        elicitation!: Bool = false,
        experimental!: JsonValue = JsonValue.objectValue([]),
        extensions!: JsonValue = JsonValue.objectValue([])
    ) {
        requireObject(experimental, "MCP experimental client capabilities")
        requireObject(extensions, "MCP client capability extensions")
        this.roots = roots
        this.sampling = sampling
        this.elicitation = elicitation
        this.experimental = experimental
        this.extensions = extensions
    }

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        match (roots) { case Some(value) => fields.add(JsonField("roots", value.toValue())); case None => () }
        if (sampling) { fields.add(JsonField("sampling", JsonValue.objectValue([]))) }
        if (elicitation) { fields.add(JsonField("elicitation", JsonValue.objectValue([]))) }
        if (!experimental.fields.isEmpty()) { fields.add(JsonField("experimental", experimental)) }
        appendMcpExtensionFields(fields, extensions)
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpServerCapabilities2026 {
    public let completion: Bool
    public let logging: Bool
    public let prompts: ?McpCapabilityFeature
    public let resources: ?McpCapabilityFeature
    public let tools: ?McpCapabilityFeature
    public let experimental: JsonValue
    public let extensions: JsonValue

    public init(
        completion!: Bool = false,
        logging!: Bool = false,
        prompts!: ?McpCapabilityFeature = None,
        resources!: ?McpCapabilityFeature = None,
        tools!: ?McpCapabilityFeature = None,
        experimental!: JsonValue = JsonValue.objectValue([]),
        extensions!: JsonValue = JsonValue.objectValue([])
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

    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        if (completion) { fields.add(JsonField("completions", JsonValue.objectValue([]))) }
        if (logging) { fields.add(JsonField("logging", JsonValue.objectValue([]))) }
        match (prompts) { case Some(value) => fields.add(JsonField("prompts", value.toValue())); case None => () }
        match (resources) { case Some(value) => fields.add(JsonField("resources", value.toValue())); case None => () }
        match (tools) { case Some(value) => fields.add(JsonField("tools", value.toValue())); case None => () }
        if (!experimental.fields.isEmpty()) { fields.add(JsonField("experimental", experimental)) }
        appendMcpExtensionFields(fields, extensions)
        JsonValue.objectValue(fields.toArray())
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
    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("name", JsonValue.stringValue(name)))
        if (description != "") { fields.add(JsonField("description", JsonValue.stringValue(description))) }
        if (required) { fields.add(JsonField("required", JsonValue.boolValue(true))) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpPrompt {
    public let name: String
    public let title: String
    public let description: String
    public let arguments: Array<McpPromptArgument>
    public let meta: JsonValue
    public init(
        name: String,
        title!: String = "",
        description!: String = "",
        arguments!: Array<McpPromptArgument> = [],
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        if (name.trimAscii() == "") { throw IllegalArgumentException("MCP prompt name must not be empty") }
        requireObject(meta, "MCP prompt metadata")
        this.name = name; this.title = title; this.description = description; this.arguments = arguments; this.meta = meta
    }
    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>(); let args = ArrayList<JsonValue>()
        fields.add(JsonField("name", JsonValue.stringValue(name)))
        if (title != "") { fields.add(JsonField("title", JsonValue.stringValue(title))) }
        if (description != "") { fields.add(JsonField("description", JsonValue.stringValue(description))) }
        for (argument in arguments) { args.add(argument.toValue()) }
        if (!args.isEmpty()) { fields.add(JsonField("arguments", JsonValue.arrayValue(args.toArray()))) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpResource {
    public let uri: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String
    public let size: ?Int64
    public let annotations: JsonValue
    public let meta: JsonValue
    public init(
        uri: String,
        name: String,
        title!: String = "",
        description!: String = "",
        mimeType!: String = "",
        size!: ?Int64 = None,
        annotations!: JsonValue = JsonValue.objectValue([]),
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        if (uri.trimAscii() == "" || name.trimAscii() == "") { throw IllegalArgumentException("MCP resource uri and name must not be empty") }
        match (size) { case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP resource size must not be negative") }; case None => () }
        requireObject(annotations, "MCP resource annotations"); requireObject(meta, "MCP resource metadata")
        this.uri = uri; this.name = name; this.title = title; this.description = description
        this.mimeType = mimeType; this.size = size; this.annotations = annotations; this.meta = meta
    }
    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("uri", JsonValue.stringValue(uri))); fields.add(JsonField("name", JsonValue.stringValue(name)))
        if (title != "") { fields.add(JsonField("title", JsonValue.stringValue(title))) }
        if (description != "") { fields.add(JsonField("description", JsonValue.stringValue(description))) }
        if (mimeType != "") { fields.add(JsonField("mimeType", JsonValue.stringValue(mimeType))) }
        match (size) { case Some(value) => fields.add(JsonField("size", JsonValue.numberValue(value.toString()))); case None => () }
        if (!annotations.fields.isEmpty()) { fields.add(JsonField("annotations", annotations)) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpResourceTemplate {
    public let uriTemplate: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String
    public let annotations: JsonValue
    public let meta: JsonValue
    public init(
        uriTemplate: String,
        name: String,
        title!: String = "",
        description!: String = "",
        mimeType!: String = "",
        annotations!: JsonValue = JsonValue.objectValue([]),
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        if (uriTemplate.trimAscii() == "" || name.trimAscii() == "") { throw IllegalArgumentException("MCP resource template and name must not be empty") }
        requireObject(annotations, "MCP resource template annotations"); requireObject(meta, "MCP resource template metadata")
        this.uriTemplate = uriTemplate; this.name = name; this.title = title; this.description = description
        this.mimeType = mimeType; this.annotations = annotations; this.meta = meta
    }
    public func toValue(): JsonValue {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("uriTemplate", JsonValue.stringValue(uriTemplate))); fields.add(JsonField("name", JsonValue.stringValue(name)))
        if (title != "") { fields.add(JsonField("title", JsonValue.stringValue(title))) }
        if (description != "") { fields.add(JsonField("description", JsonValue.stringValue(description))) }
        if (mimeType != "") { fields.add(JsonField("mimeType", JsonValue.stringValue(mimeType))) }
        if (!annotations.fields.isEmpty()) { fields.add(JsonField("annotations", annotations)) }
        if (!meta.fields.isEmpty()) { fields.add(JsonField("_meta", meta)) }
        JsonValue.objectValue(fields.toArray())
    }
}

public class McpPage {
    public let values: Array<JsonValue>
    public let nextCursor: String
    public let ttlMillis: Int64
    public let cacheScope: String
    public init(values: Array<JsonValue>, nextCursor!: String = "", ttlMillis!: Int64 = 300000, cacheScope!: String = "private") {
        if (ttlMillis < 0 || !validMcpCacheScope(cacheScope)) { throw IllegalArgumentException("invalid MCP page cache metadata") }
        this.values = values; this.nextCursor = nextCursor; this.ttlMillis = ttlMillis; this.cacheScope = cacheScope
    }
    public func toValue(fieldName: String): JsonValue {
        if (fieldName.trimAscii() == "") { throw IllegalArgumentException("MCP page field name must not be empty") }
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("resultType", JsonValue.stringValue(MCP_RESULT_COMPLETE)))
        fields.add(JsonField(fieldName, JsonValue.arrayValue(values)))
        if (nextCursor != "") { fields.add(JsonField("nextCursor", JsonValue.stringValue(nextCursor))) }
        fields.add(JsonField("ttlMs", JsonValue.numberValue(ttlMillis.toString())))
        fields.add(JsonField("cacheScope", JsonValue.stringValue(cacheScope)))
        JsonValue.objectValue(fields.toArray())
    }
}

public enum McpOperationOutcome<T> {
    Complete(T) | InputRequired(McpInputRequiredResult) | Extension(String, JsonValue)
}

public interface McpInputResolver {
    func resolve(requests: JsonValue, requestState: String): McpResult<JsonValue>
}

public class McpResolutionPolicy {
    public let maxRounds: Int64
    public init(maxRounds!: Int64 = 10) {
        if (maxRounds <= 0 || maxRounds > 10) { throw IllegalArgumentException("MCP input resolution maxRounds must be in 1..10") }
        this.maxRounds = maxRounds
    }
}

func appendMcpExtensionFields(fields: ArrayList<JsonField>, extensions: JsonValue): Unit {
    for (extension in extensions.fields) {
        var duplicate = false
        for (field in fields where field.name == extension.name) { duplicate = true; break }
        if (!duplicate) { fields.add(extension) }
    }
}
