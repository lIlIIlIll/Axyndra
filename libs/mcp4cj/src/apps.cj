package mcp4cj

import yjson.*
import yjson_support.*
import std.collection.*

public let MCP_APPS_EXTENSION = "io.modelcontextprotocol/ui"
public let MCP_APPS_PROTOCOL_VERSION = "2026-01-26"
public let MCP_APPS_MIME_TYPE = "text/html;profile=mcp-app"
public let MCP_APPS_UI_META = "ui"

public let MCP_APPS_METHOD_INITIALIZE = "ui/initialize"
public let MCP_APPS_METHOD_OPEN_LINK = "ui/open-link"
public let MCP_APPS_METHOD_DOWNLOAD_FILE = "ui/download-file"
public let MCP_APPS_METHOD_MESSAGE = "ui/message"
public let MCP_APPS_METHOD_UPDATE_MODEL_CONTEXT = "ui/update-model-context"
public let MCP_APPS_METHOD_RESOURCE_TEARDOWN = "ui/resource-teardown"
public let MCP_APPS_METHOD_REQUEST_DISPLAY_MODE = "ui/request-display-mode"
public let MCP_APPS_NOTIFICATION_INITIALIZED = "ui/notifications/initialized"
public let MCP_APPS_NOTIFICATION_SIZE_CHANGED = "ui/notifications/size-changed"
public let MCP_APPS_NOTIFICATION_TOOL_INPUT = "ui/notifications/tool-input"
public let MCP_APPS_NOTIFICATION_TOOL_INPUT_PARTIAL = "ui/notifications/tool-input-partial"
public let MCP_APPS_NOTIFICATION_TOOL_RESULT = "ui/notifications/tool-result"
public let MCP_APPS_NOTIFICATION_TOOL_CANCELLED = "ui/notifications/tool-cancelled"
public let MCP_APPS_NOTIFICATION_HOST_CONTEXT_CHANGED = "ui/notifications/host-context-changed"
public let MCP_APPS_NOTIFICATION_REQUEST_TEARDOWN = "ui/notifications/request-teardown"

public class McpAppResource {
    public let uri: String
    public let html: String
    public let csp: JsonNode
    public let permissions: JsonNode
    public let domain: String
    public let prefersBorder: ?Bool
    public let meta: JsonNode
    public init(
        uri: String,
        html: String,
        csp!: JsonNode = jsonObject([]),
        permissions!: JsonNode = jsonObject([]),
        domain!: String = "",
        prefersBorder!: ?Bool = None,
        meta!: JsonNode = jsonObject([])
    ) {
        if (!validMcpAppResourceUri(uri) || html.trimAscii() == "") {
            throw IllegalArgumentException("MCP App resource requires ui:// URI and HTML")
        }
        requireObject(csp, "MCP App CSP"); requireObject(permissions, "MCP App permissions")
        requireObject(meta, "MCP App metadata")
        match (validateMcpAppCsp(csp)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => throw IllegalArgumentException(error.message)
        }
        match (validateMcpAppPermissions(permissions)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => throw IllegalArgumentException(error.message)
        }
        if (domain != "" && !validMcpAppDomain(domain)) {
            throw IllegalArgumentException("MCP App domain must be a host name without scheme or path")
        }
        this.uri = uri; this.html = html; this.csp = csp; this.permissions = permissions
        this.domain = domain; this.prefersBorder = prefersBorder; this.meta = meta
    }

    public func toResourceContent(): JsonNode {
        let metadata = ArrayList<JsonObjectEntry>()
        for (field in meta.fields where field.name != MCP_APPS_UI_META) { metadata.add(field) }
        let ui = ArrayList<JsonObjectEntry>()
        if (!csp.fields.isEmpty()) { ui.add(JsonObjectEntry("csp", csp)) }
        if (!permissions.fields.isEmpty()) { ui.add(JsonObjectEntry("permissions", permissions)) }
        if (domain != "") { ui.add(JsonObjectEntry("domain", jsonString(domain))) }
        match (prefersBorder) {
            case Some(value) => ui.add(JsonObjectEntry("prefersBorder", jsonBool(value)))
            case None => ()
        }
        if (!ui.isEmpty()) { metadata.add(JsonObjectEntry(MCP_APPS_UI_META, jsonObject(ui.toArray()))) }
        jsonObject([
            JsonObjectEntry("uri", jsonString(uri)),
            JsonObjectEntry("mimeType", jsonString(MCP_APPS_MIME_TYPE)),
            JsonObjectEntry("text", jsonString(html)),
            JsonObjectEntry("_meta", jsonObject(metadata.toArray()))
        ])
    }
}

public func validateMcpAppToolMeta(meta: JsonNode): McpResult<Unit> {
    if (meta.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<Unit>("mcp.apps.meta_invalid", "MCP App tool metadata must be an object")
    }
    let ui = match (meta.field(MCP_APPS_UI_META)) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else {
            return invalidMcp<Unit>("mcp.apps.ui_invalid", "MCP App tool ui metadata must be an object")
        }
        case None => return McpResult.Ok(())
    }
    if (ui.field("csp").isSome() || ui.field("permissions").isSome()) {
        return invalidMcp<Unit>("mcp.apps.security_meta_misplaced", "MCP App csp and permissions belong on the UI resource")
    }
    match (ui.field("resourceUri")) {
        case Some(value) => if (value.unifiedKind != UnifiedJsonKind.Text || !validMcpAppResourceUri(value.text)) {
            return invalidMcp<Unit>("mcp.apps.resource_uri_invalid", "MCP App resourceUri must use ui://")
        }
        case None => ()
    }
    match (ui.field("visibility")) {
        case Some(value) =>
            if (value.unifiedKind != UnifiedJsonKind.List || value.items.isEmpty()) {
                return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility must be a non-empty array")
            }
            var model = false; var app = false
            for (entry in value.items) {
                if (entry.unifiedKind != UnifiedJsonKind.Text || (entry.text != "model" && entry.text != "app")) {
                    return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility entries must be model or app")
                }
                if ((entry.text == "model" && model) || (entry.text == "app" && app)) {
                    return invalidMcp<Unit>("mcp.apps.visibility_invalid", "MCP App visibility entries must be unique")
                }
                if (entry.text == "model") { model = true } else { app = true }
            }
        case None => ()
    }
    McpResult.Ok(())
}

public func validateMcpAppResourceContent(content: JsonNode): McpResult<Unit> {
    if (content.unifiedKind != UnifiedJsonKind.Object || !validMcpAppResourceUri(mcpText(content, "uri")) ||
        mcpText(content, "mimeType") != MCP_APPS_MIME_TYPE || mcpText(content, "text") == "") {
        return invalidMcp<Unit>("mcp.apps.resource_invalid", "invalid MCP App HTML resource content")
    }
    let ui = mcpObject(mcpObject(content, "_meta"), MCP_APPS_UI_META)
    match (validateMcpAppCsp(mcpObject(ui, "csp"))) {
        case McpResult.Ok(_) => validateMcpAppPermissions(mcpObject(ui, "permissions"))
        case McpResult.Err(error) => McpResult.Err(error)
    }
}

public func validateMcpAppCsp(csp: JsonNode): McpResult<Unit> {
    if (csp.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<Unit>("mcp.apps.csp_invalid", "MCP App CSP must be an object")
    }
    for (field in csp.fields) {
        if (field.name != "connectDomains" && field.name != "resourceDomains" &&
            field.name != "frameDomains" && field.name != "baseUriDomains") {
            return invalidMcp<Unit>("mcp.apps.csp_invalid", "MCP App CSP contains an unknown directive")
        }
        if (field.value.unifiedKind != UnifiedJsonKind.List) {
            return invalidMcp<Unit>("mcp.apps.csp_invalid", "MCP App CSP domains must be arrays")
        }
        for (domain in field.value.items where domain.unifiedKind != UnifiedJsonKind.Text || !validMcpAppOrigin(domain.text)) {
            return invalidMcp<Unit>("mcp.apps.csp_origin_invalid", "MCP App CSP origins must be secure explicit origins")
        }
    }
    McpResult.Ok(())
}

public func validateMcpAppPermissions(permissions: JsonNode): McpResult<Unit> {
    if (permissions.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<Unit>("mcp.apps.permissions_invalid", "MCP App permissions must be an object")
    }
    for (field in permissions.fields) {
        if (field.name != "camera" && field.name != "microphone" && field.name != "geolocation" && field.name != "clipboardWrite") {
            return invalidMcp<Unit>("mcp.apps.permissions_invalid", "MCP App permission is not defined by the protocol")
        }
        if (field.value.unifiedKind != UnifiedJsonKind.Object || !field.value.fields.isEmpty()) {
            return invalidMcp<Unit>("mcp.apps.permissions_invalid", "MCP App permission values must be empty objects")
        }
    }
    McpResult.Ok(())
}

public interface McpAppHostPolicy {
    func allowResource(uri: String, metadata: JsonNode): McpResult<Unit>
    func allowToolCall(name: String, arguments: JsonNode): McpResult<Unit>
    func allowOpenExternal(uri: String): McpResult<Unit>
}

func validMcpAppResourceUri(value: String): Bool {
    value.startsWith("ui://") && value.size > 5 && value.indexOf(" ").isNone() && value.indexOf("#").isNone()
}

func validMcpAppOrigin(value: String): Bool {
    if (value.startsWith("https://") || value.startsWith("wss://")) {
        let rest = value[value.indexOf("//").getOrThrow() + 2..]
        return rest != "" && rest.indexOf(" ").isNone() && rest.indexOf("/").isNone()
    }
    false
}

func validMcpAppDomain(value: String): Bool {
    value != "" && value.indexOf("://").isNone() && value.indexOf("/").isNone() &&
        value.indexOf(" ").isNone() && value.indexOf(".").isSome()
}
