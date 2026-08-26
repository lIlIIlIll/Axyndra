package mcp4cj

import yjson.*
import yjson_support.*
import std.collection.*

public let MCP_APPS_MIME_TYPE = "text/html;profile=mcp-app"
public let MCP_APPS_RESOURCE_URI_META = "ui/resourceUri"
public let MCP_APPS_VISIBILITY_META = "ui/visibility"

public class McpAppResource {
    public let uri: String
    public let html: String
    public let csp: JsonNode
    public let permissions: JsonNode
    public let meta: JsonNode
    public init(
        uri: String,
        html: String,
        csp!: JsonNode = jsonObject([]),
        permissions!: JsonNode = jsonObject([]),
        meta!: JsonNode = jsonObject([])
    ) {
        if (uri.trimAscii() == "" || html.trimAscii() == "") { throw IllegalArgumentException("MCP App resource requires uri and HTML") }
        requireObject(csp, "MCP App CSP"); requireObject(permissions, "MCP App permissions"); requireObject(meta, "MCP App metadata")
        this.uri = uri; this.html = html; this.csp = csp; this.permissions = permissions; this.meta = meta
    }
    public func toResourceContent(): JsonNode {
        let metadata = ArrayList<JsonObjectEntry>()
        for (field in meta.fields) { metadata.add(field) }
        if (!csp.fields.isEmpty()) { metadata.add(JsonObjectEntry("ui/csp", csp)) }
        if (!permissions.fields.isEmpty()) { metadata.add(JsonObjectEntry("ui/permissions", permissions)) }
        jsonObject([
            JsonObjectEntry("uri", jsonString(uri)),
            JsonObjectEntry("mimeType", jsonString(MCP_APPS_MIME_TYPE)),
            JsonObjectEntry("text", jsonString(html)),
            JsonObjectEntry("_meta", jsonObject(metadata.toArray()))
        ])
    }
}

public func validateMcpAppToolMeta(meta: JsonNode): McpResult<Unit> {
    if (meta.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<Unit>("mcp.apps.meta_invalid", "MCP App tool metadata must be an object") }
    match (meta.field(MCP_APPS_RESOURCE_URI_META)) {
        case Some(value) => if (value.unifiedKind != UnifiedJsonKind.Text || value.text.trimAscii() == "") {
            return invalidMcp<Unit>("mcp.apps.resource_uri_invalid", "MCP App resource URI must be a non-empty string")
        }
        case None => return invalidMcp<Unit>("mcp.apps.resource_uri_missing", "MCP App tool metadata requires ui/resourceUri")
    }
    match (meta.field(MCP_APPS_VISIBILITY_META)) {
        case Some(value) =>
            if (value.unifiedKind != UnifiedJsonKind.List || value.items.isEmpty()) { return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility must be a non-empty array") }
            for (entry in value.items where entry.unifiedKind != UnifiedJsonKind.Text || (entry.text != "model" && entry.text != "app")) {
                return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility entries must be model or app")
            }
        case None => ()
    }
    McpResult.Ok(())
}

public interface McpAppHostPolicy {
    func allowResource(uri: String, metadata: JsonNode): McpResult<Unit>
    func allowToolCall(name: String, arguments: JsonNode): McpResult<Unit>
    func allowOpenExternal(uri: String): McpResult<Unit>
}
