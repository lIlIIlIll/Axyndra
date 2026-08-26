package mcp4cj

import json4cj.*
import std.collection.*

public let MCP_APPS_MIME_TYPE = "text/html;profile=mcp-app"
public let MCP_APPS_RESOURCE_URI_META = "ui/resourceUri"
public let MCP_APPS_VISIBILITY_META = "ui/visibility"

public class McpAppResource {
    public let uri: String
    public let html: String
    public let csp: JsonValue
    public let permissions: JsonValue
    public let meta: JsonValue
    public init(
        uri: String,
        html: String,
        csp!: JsonValue = JsonValue.objectValue([]),
        permissions!: JsonValue = JsonValue.objectValue([]),
        meta!: JsonValue = JsonValue.objectValue([])
    ) {
        if (uri.trimAscii() == "" || html.trimAscii() == "") { throw IllegalArgumentException("MCP App resource requires uri and HTML") }
        requireObject(csp, "MCP App CSP"); requireObject(permissions, "MCP App permissions"); requireObject(meta, "MCP App metadata")
        this.uri = uri; this.html = html; this.csp = csp; this.permissions = permissions; this.meta = meta
    }
    public func toResourceContent(): JsonValue {
        let metadata = ArrayList<JsonField>()
        for (field in meta.fields) { metadata.add(field) }
        if (!csp.fields.isEmpty()) { metadata.add(JsonField("ui/csp", csp)) }
        if (!permissions.fields.isEmpty()) { metadata.add(JsonField("ui/permissions", permissions)) }
        JsonValue.objectValue([
            JsonField("uri", JsonValue.stringValue(uri)),
            JsonField("mimeType", JsonValue.stringValue(MCP_APPS_MIME_TYPE)),
            JsonField("text", JsonValue.stringValue(html)),
            JsonField("_meta", JsonValue.objectValue(metadata.toArray()))
        ])
    }
}

public func validateMcpAppToolMeta(meta: JsonValue): McpResult<Unit> {
    if (meta.kind != JsonKind.Object) { return invalidMcp<Unit>("mcp.apps.meta_invalid", "MCP App tool metadata must be an object") }
    match (meta.field(MCP_APPS_RESOURCE_URI_META)) {
        case Some(value) => if (value.kind != JsonKind.Text || value.text.trimAscii() == "") {
            return invalidMcp<Unit>("mcp.apps.resource_uri_invalid", "MCP App resource URI must be a non-empty string")
        }
        case None => return invalidMcp<Unit>("mcp.apps.resource_uri_missing", "MCP App tool metadata requires ui/resourceUri")
    }
    match (meta.field(MCP_APPS_VISIBILITY_META)) {
        case Some(value) =>
            if (value.kind != JsonKind.List || value.items.isEmpty()) { return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility must be a non-empty array") }
            for (entry in value.items where entry.kind != JsonKind.Text || (entry.text != "model" && entry.text != "app")) {
                return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility entries must be model or app")
            }
        case None => ()
    }
    McpResult.Ok(())
}

public interface McpAppHostPolicy {
    func allowResource(uri: String, metadata: JsonValue): McpResult<Unit>
    func allowToolCall(name: String, arguments: JsonValue): McpResult<Unit>
    func allowOpenExternal(uri: String): McpResult<Unit>
}
