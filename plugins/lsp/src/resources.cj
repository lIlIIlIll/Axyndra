package lsp_plugin

import std.collection.*
import yjson.*
import yjson_support.*

let LSP_READ_INPUT = "_axyndra_context_read"

func lspRelativeResource(path: String): Bool {
    if (path == "" || path.size > 4096 || path.startsWith("/") || path.contains("\\") || path.contains(":")) { return false }
    for (byte in path.toArray() where byte < 32u8 || byte == 127u8) { return false }
    for (part in path.split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}
func lspResourceRoot(configuration: LspConfiguration): String {
    let value = languageUriPath(configuration.rootUri)
    let root = if (value.size > 1 && value.endsWith("/")) { value[..value.size - 1] } else { value }
    require(root.startsWith("/") && (root == "/" || lspRelativeResource(root[1..])), "lsp_plugin.resource_uri_invalid")
    root
}
func lspResourceSource(configuration: LspConfiguration, path: String): String {
    require(lspRelativeResource(path), "lsp_plugin.resource_path_invalid")
    let root = lspResourceRoot(configuration)
    (if (root == "/") { root } else { root + "/" }) + path
}
func lspResourceUri(configuration: LspConfiguration, path: String): String {
    require(lspRelativeResource(path), "lsp_plugin.resource_path_invalid")
    let encoded = ArrayList<Byte>(); let digits = "0123456789ABCDEF".toArray()
    for (byte in path.toArray()) {
        if ((byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) ||
            byte == 45u8 || byte == 46u8 || byte == 95u8 || byte == 126u8 || byte == 47u8) { encoded.add(byte) }
        else { encoded.add(37u8); encoded.add(digits[Int64(byte) / 16]); encoded.add(digits[Int64(byte) % 16]) }
    }
    (if (configuration.rootUri.endsWith("/")) { configuration.rootUri } else { configuration.rootUri + "/" }) + String.fromUtf8(encoded.toArray())
}

// No filesystem API: missing document text yields a pure request. A bounded
// canonical host read must finish before another pure prepare can freeze bytes.
func lspResourceReadRequest(input: JsonNode, configuration: LspConfiguration): ?JsonNode {
    if (input.field(LSP_READ_INPUT).isSome()) { return None }
    exact(input, ["documents", "params", "method"])
    let documents = field(input, "documents")
    require(documents.unifiedKind == UnifiedJsonKind.List && documents.items.size <= 16)
    let resources = ArrayList<JsonNode>(); let paths = HashSet<String>()
    for (document in documents.items) {
        if (document.field("path").isNone()) { exact(document, ["uri", "version", "text"]); continue }
        exact(document, ["path", "version"])
        let path = text(document, "path")
        require(lspRelativeResource(path) && number(document, "version") > 0 && !paths.contains(path), "lsp_plugin.resource_path_invalid")
        paths.add(path)
        resources.add(jsonObject([JsonObjectEntry("source", jsonString(lspResourceSource(configuration, path))),
            JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("mode", jsonString("file"))]))
    }
    if (resources.isEmpty()) { return None }
    Some(jsonObject([JsonObjectEntry("context_read", jsonObject([JsonObjectEntry("resources", jsonArray(resources.toArray()))]))]))
}

func lspMaterializeResources(input: JsonNode, configuration: LspConfiguration): JsonNode {
    if (input.field(LSP_READ_INPUT).isNone()) { return input }
    exact(input, ["documents", "params", "method", LSP_READ_INPUT])
    let envelope = field(input, LSP_READ_INPUT)
    exact(envelope, ["schema", "data", "facts"])
    require(text(envelope, "schema") == "axyndra.context-read-input/v1" &&
        field(envelope, "facts").unifiedKind == UnifiedJsonKind.List && field(envelope, "facts").items.size == 1,
        "lsp_plugin.resource_fact_invalid")
    let data = field(envelope, "data"); exact(data, ["schema", "resources"])
    require(text(data, "schema") == "axyndra.context-read-result/v1", "lsp_plugin.resource_fact_invalid")
    let resources = field(data, "resources")
    require(resources.unifiedKind == UnifiedJsonKind.List && resources.items.size <= 16, "lsp_plugin.resource_fact_invalid")
    let byPath = HashMap<String, JsonNode>()
    for (item in resources.items) {
        exact(item, ["kind", "source", "path", "witness", "text", "sha256"])
        let path = text(item, "path")
        require(text(item, "kind") == "file" && lspRelativeResource(path) && !byPath.contains(path) &&
            text(item, "source") == lspResourceSource(configuration, path) && text(item, "witness") != "" &&
            field(item, "text").unifiedKind == UnifiedJsonKind.Text && sha(text(item, "text")) == text(item, "sha256"),
            "lsp_plugin.resource_fact_invalid")
        byPath.add(path, item)
    }
    let documents = field(input, "documents")
    require(documents.unifiedKind == UnifiedJsonKind.List && documents.items.size <= 16)
    let mapped = ArrayList<JsonNode>(); var used: Int64 = 0
    for (document in documents.items) {
        if (document.field("path").isNone()) { exact(document, ["uri", "version", "text"]); mapped.add(document); continue }
        exact(document, ["path", "version"]); let path = text(document, "path")
        let content = byPath.get(path).getOrThrow(); require(number(document, "version") > 0)
        mapped.add(jsonObject([JsonObjectEntry("uri", jsonString(lspResourceUri(configuration, path))),
            JsonObjectEntry("version", field(document, "version")), JsonObjectEntry("text", field(content, "text"))]))
        byPath.remove(path); used++
    }
    require(used > 0 && byPath.isEmpty(), "lsp_plugin.resource_fact_unused")
    jsonObject([JsonObjectEntry("documents", jsonArray(mapped.toArray())), JsonObjectEntry("params", field(input, "params")),
        JsonObjectEntry("method", field(input, "method"))])
}
