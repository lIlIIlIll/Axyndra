package lsp_plugin

import lsp4cj.*
import std.collection.*
import yjson.*
import yjson_support.*

func actionNames(): Array<String> { ["definition", "type_definition", "implementation", "references", "hover", "symbols", "diagnostics", "rename", "code_actions", "rename_file", "request", "notify"] }
func actionDirectory(): JsonNode {
    let entries = ArrayList<JsonNode>()
    for (name in actionNames()) {
        let schema = jsonObject([JsonObjectEntry("type", jsonString("object")),
            JsonObjectEntry("properties", jsonObject([JsonObjectEntry("documents", jsonObject([JsonObjectEntry("type", jsonString("array")), JsonObjectEntry("maxItems", jsonNumber("16"))])),
                JsonObjectEntry("params", jsonObject([JsonObjectEntry("type", jsonString("object"))])),
                JsonObjectEntry("method", jsonObject([JsonObjectEntry("type", jsonString("string"))]))])),
            JsonObjectEntry("required", jsonArray([jsonString("documents"), jsonString("params"), jsonString("method")])),
            JsonObjectEntry("additionalProperties", jsonBool(false))])
        let edit = ["rename", "code_actions", "rename_file"].contains(name)
        entries.add(jsonObject([JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("input_schema", schema),
            JsonObjectEntry("description", jsonString("LSP " + name + "; documents accept explicit uri/version/text or relative path/version through an approved host read" + (if (edit) { "; returns unapplied edit data" } else { "; frozen protocol parameters" })))]))
    }
    jsonObject([JsonObjectEntry("tools", jsonArray(entries.toArray()))])
}
func actionMethod(name: String, input: JsonNode): String {
    match (name) {
        case "definition" => "textDocument/definition"
        case "type_definition" => "textDocument/typeDefinition"
        case "implementation" => "textDocument/implementation"
        case "references" => "textDocument/references"
        case "hover" => "textDocument/hover"
        case "symbols" => if (field(input, "params").field("textDocument").isSome()) { "textDocument/documentSymbol" } else { "workspace/symbol" }
        case "diagnostics" => "textDocument/diagnostic"
        case "rename" => "textDocument/rename"
        case "code_actions" => "textDocument/codeAction"
        case "rename_file" => "workspace/willRenameFiles"
        case "request" | "notify" => let method = text(input, "method"); require(method != "" && method.size <= 256); method
        case _ => throw PluginFailure("lsp_plugin.action_unknown")
    }
}
class DocumentUpdate {
    let uri: String
    let version: Int64
    let notification: LspNotification
    init(uri: String, version: Int64, notification: LspNotification) { this.uri = uri; this.version = version; this.notification = notification }
}
func documentUpdates(input: JsonNode, configuration: LspConfiguration, versions: HashMap<String, Int64>): Array<DocumentUpdate> {
    exact(input, ["documents", "params", "method"])
    require(field(input, "params").unifiedKind == UnifiedJsonKind.Object && field(input, "method").unifiedKind == UnifiedJsonKind.Text)
    let documents = field(input, "documents")
    require(documents.unifiedKind == UnifiedJsonKind.List && documents.items.size <= 16)
    let result = ArrayList<DocumentUpdate>(); let names = HashSet<String>()
    for (document in documents.items) {
        exact(document, ["uri", "version", "text"])
        let uri = text(document, "uri"); let version = number(document, "version")
        require(configuration.admitsUri(uri) && !names.contains(uri) && version > 0 && field(document, "text").unifiedKind == UnifiedJsonKind.Text)
        names.add(uri)
        let prior = versions.get(uri)
        require(prior.isNone() || version > prior.getOrThrow(), "lsp_plugin.document_version_stale")
        let identifier = jsonObject([JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("version", jsonNumber(version.toString()))])
        let notification = if (prior.isSome()) {
            LspNotification("textDocument/didChange", jsonObject([JsonObjectEntry("textDocument", identifier),
                JsonObjectEntry("contentChanges", jsonArray([jsonObject([JsonObjectEntry("text", field(document, "text"))])]))]))
        } else {
            LspNotification("textDocument/didOpen", jsonObject([JsonObjectEntry("textDocument", jsonObject([
                JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("version", jsonNumber(version.toString())),
                JsonObjectEntry("languageId", jsonString(configuration.languageId)), JsonObjectEntry("text", field(document, "text"))]))]))
        }
        result.add(DocumentUpdate(uri, version, notification))
    }
    result.toArray()
}
