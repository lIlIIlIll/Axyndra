package mcp_client_plugin

import mcp4cj.*
import std.collection.*
import yjson.*
import yjson_support.*

// Business configuration only. The URL and opaque references are requests;
// matching operator grants and actual credentials belong solely to the host.
class McpPluginConfiguration {
    let requestTimeoutMillis: Int64
    let maxFrameBytes: Int64
    let gracefulShutdownMillis: Int64
    let maxPages: Int64
    let maxTools: Int64
    let transport: String
    let url: String
    let credentialRefs: Array<String>
    let maxResponseBytes: Int64
    let preferSse: Bool
    let origin: String
    let headers: Array<McpHttpHeader>
    let identity: String
    let limits: ProtocolLimits
    init(value: JsonNode, limits!: ProtocolLimits = ProtocolLimits()) {
        this.limits = limits
        transport = text(value, "transport")
        let configurationFields = ArrayList<String>(["version", "transport", "request_timeout_ms", "directory"])
        if (transport == "http") { configurationFields.add("http") }
        if (value.field("framing").isSome()) { configurationFields.add("framing") }
        exact(value, configurationFields.toArray())
        require(number(value, "version") == 1 && (transport == "stdio" || transport == "http"),
            "mcp_plugin.configuration_unsupported")
        let directory = field(value, "directory")
        exact(directory, ["max_pages", "max_tools"])
        requestTimeoutMillis = number(value, "request_timeout_ms")
        maxPages = number(directory, "max_pages")
        maxTools = number(directory, "max_tools")
        require(requestTimeoutMillis >= 1 && requestTimeoutMillis <= limits.timeout &&
            maxPages >= 1 && maxPages <= (if (limits.isExplicit) { 1024 } else { 8 }) && maxTools >= 1 && maxTools <= limits.tools,
            "mcp_plugin.configuration_limit")
        if (value.field("framing").isSome()) {
            let framing = field(value, "framing")
            exact(framing, ["max_frame_bytes", "graceful_shutdown_ms"])
            maxFrameBytes = canonicalNumber(framing, "max_frame_bytes", 1024, limits.result)
            gracefulShutdownMillis = canonicalNumber(framing, "graceful_shutdown_ms", 0, 9223372036854775807)
        } else { maxFrameBytes = limits.result; gracefulShutdownMillis = 0 }
        let base = ArrayList<JsonObjectEntry>([
            JsonObjectEntry("version", jsonNumber("1")), JsonObjectEntry("transport", jsonString(transport)),
            JsonObjectEntry("request_timeout_ms", jsonNumber(requestTimeoutMillis.toString())),
            JsonObjectEntry("directory", jsonObject([JsonObjectEntry("max_pages", jsonNumber(maxPages.toString())),
                JsonObjectEntry("max_tools", jsonNumber(maxTools.toString()))]))])
        base.add(JsonObjectEntry("framing", jsonObject([
            JsonObjectEntry("max_frame_bytes", jsonNumber(maxFrameBytes.toString())),
            JsonObjectEntry("graceful_shutdown_ms", jsonNumber(gracefulShutdownMillis.toString()))])))
        if (transport == "http") {
            let http = field(value, "http")
            let fields = ArrayList<String>(["url", "credential_refs", "max_response_bytes", "prefer_sse"])
            if (http.field("origin").isSome()) { fields.add("origin") }
            if (http.field("headers").isSome()) { fields.add("headers") }
            exact(http, fields.toArray())
            if (http.field("origin").isSome()) { require(field(http, "origin").unifiedKind == UnifiedJsonKind.Text, "mcp_plugin.http_origin_invalid") }
            origin = if (http.field("origin").isSome()) { text(http, "origin") } else { "" }
            require(origin.size <= 2048, "mcp_plugin.http_origin_invalid")
            headers = mcpPluginPublicHttpHeaders(http.field("headers") ?? jsonObject([]))
            url = text(http, "url")
            require(url.size <= 16384 && !url.contains("#") && !url.contains("\\"),
                "mcp_plugin.http_url_invalid")
            for (byte in url.toArray() where byte < 33u8 || byte > 126u8) {
                throw PluginFailure("mcp_plugin.http_url_invalid")
            }
            let prefix: Int64 = if (url.startsWith("https://")) { 8 } else if (url.startsWith("http://")) { 7 } else { 0 }
            require(prefix > 0 && url.size > prefix, "mcp_plugin.http_url_invalid")
            let remainder = url[prefix..]
            var end = remainder.size
            match (remainder.indexOf("/")) { case Some(index) => end = index; case None => () }
            match (remainder.indexOf("?")) { case Some(index) => if (index < end) { end = index }; case None => () }
            require(end > 0 && !remainder[..end].contains("@"), "mcp_plugin.http_url_invalid")
            // Reuse the library's HTTPS/loopback URL validation, without
            // constructing its direct-network default exchange backend.
            let _ = McpStreamableHttpClientConfig(url, origin: origin, headers: headers)
            let refs = field(http, "credential_refs")
            require(refs.unifiedKind == UnifiedJsonKind.List && refs.items.size <= 4,
                "mcp_plugin.http_refs_invalid")
            let names = ArrayList<String>(); let seen = HashSet<String>()
            for (ref in refs.items) {
                require(ref.unifiedKind == UnifiedJsonKind.Text && ref.text != "" && ref.text.size <= 128 &&
                    !seen.contains(ref.text), "mcp_plugin.http_refs_invalid")
                for (byte in ref.text.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
                    (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) ||
                    byte == 45u8 || byte == 46u8 || byte == 95u8 || byte == 58u8)) {
                    throw PluginFailure("mcp_plugin.http_refs_invalid")
                }
                seen.add(ref.text); names.add(ref.text)
            }
            credentialRefs = names.toArray()
            maxResponseBytes = canonicalNumber(http, "max_response_bytes", 1024, match (limits.payload) { case Some(value) => value.result; case None => 1048576 })
            require(field(http, "prefer_sse").unifiedKind == UnifiedJsonKind.Boolean)
            preferSse = boolean(http, "prefer_sse")
            base.add(JsonObjectEntry("http", jsonObject([JsonObjectEntry("url", jsonString(url)),
                JsonObjectEntry("credential_refs", jsonArray(credentialRefs.map { ref => jsonString(ref) })),
                JsonObjectEntry("max_response_bytes", jsonNumber(maxResponseBytes.toString())),
                JsonObjectEntry("prefer_sse", jsonBool(preferSse)),
                JsonObjectEntry("origin", jsonString(origin)), JsonObjectEntry("headers", jsonObject(
                    headers.map { item => JsonObjectEntry(item.name, jsonString(item.value)) }))])))
        } else { url = ""; credentialRefs = []; maxResponseBytes = 65536; preferSse = false; origin = ""; headers = [] }
        identity = stringifyUnifiedJson(jsonObject(base.toArray()))
    }
}

// These values are explicitly nonsecret plugin configuration. Authentication
// still uses opaque credential refs resolved by the canonical host service.
func mcpPluginPublicHttpHeaders(value: JsonNode): Array<McpHttpHeader> {
    require(value.unifiedKind == UnifiedJsonKind.Object && value.fields.size <= 16,
        "mcp_plugin.http_header_invalid")
    let result = ArrayList<McpHttpHeader>(); let seen = HashSet<String>()
    for (entry in value.fields) {
        let name = entry.name.toAsciiLower()
        require(name != "" && name.size <= 128 && !seen.contains(name) &&
            !name.startsWith("proxy-") && !name.startsWith("sec-") && !name.startsWith("mcp-") &&
            !["host", "authorization", "cookie", "cookie2", "connection", "transfer-encoding", "origin",
              "content-length", "content-type", "accept", "expect", "accept-encoding", "te", "trailer", "upgrade"].contains(name),
            "mcp_plugin.http_header_invalid")
        require(entry.value.unifiedKind == UnifiedJsonKind.Text && entry.value.text.size <= 8192,
            "mcp_plugin.http_header_invalid")
        for (byte in name.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
            (byte >= 97u8 && byte <= 122u8) || byte == 45u8)) { throw PluginFailure("mcp_plugin.http_header_invalid") }
        for (byte in entry.value.text.toArray() where byte < 32u8 || byte > 126u8) {
            throw PluginFailure("mcp_plugin.http_header_invalid")
        }
        seen.add(name); result.add(McpHttpHeader(entry.name, entry.value.text))
    }
    result.toArray()
}
