package lsp_plugin

import yjson.*
import yjson_support.*

class LspConfiguration {
    let rootUri: String
    let languageId: String
    let timeoutMillis: Int64
    let identity: String
    private let options: String
    private let settings: String
    init(value: JsonNode, limits: ProtocolLimits) {
        exact(value, ["version", "root_uri", "language_id", "initialization_options", "settings", "request_timeout_ms"])
        require(number(value, "version") == 1 && field(value, "version").asNumberText() == "1", "lsp_plugin.configuration_version")
        let root = text(value, "root_uri"); let language = text(value, "language_id")
        require(root.startsWith("file:///") && root.size <= 4096 && !root.contains("\u{0000}") &&
            language != "" && language.size <= 128, "lsp_plugin.configuration_invalid")
        require(field(value, "initialization_options").unifiedKind == UnifiedJsonKind.Object &&
            field(value, "settings").unifiedKind == UnifiedJsonKind.Object, "lsp_plugin.configuration_invalid")
        let timeout = number(value, "request_timeout_ms")
        require(timeout >= 1 && timeout <= limits.timeout, "lsp_plugin.configuration_timeout")
        let encoded = stringifyUnifiedJson(value)
        require(encoded.size <= 16384, "lsp_plugin.configuration_limit")
        rootUri = root; languageId = language; timeoutMillis = timeout; identity = sha(encoded)
        options = stringifyUnifiedJson(field(value, "initialization_options")); settings = stringifyUnifiedJson(field(value, "settings"))
    }
    func initialization(): JsonNode {
        jsonObject([JsonObjectEntry("processId", jsonNull()), JsonObjectEntry("rootUri", jsonString(rootUri)),
            JsonObjectEntry("clientInfo", jsonObject([JsonObjectEntry("name", jsonString("Axyndra independent LSP")), JsonObjectEntry("version", jsonString("1.0.0"))])),
            JsonObjectEntry("capabilities", jsonObject([JsonObjectEntry("general", jsonObject([JsonObjectEntry("positionEncodings", jsonArray([jsonString("utf-16")]))])),
                JsonObjectEntry("workspace", jsonObject([JsonObjectEntry("applyEdit", jsonBool(false)),
                    JsonObjectEntry("workspaceEdit", jsonObject([JsonObjectEntry("documentChanges", jsonBool(true))]))]))])),
            JsonObjectEntry("initializationOptions", parseUnifiedJson(options, maxBytes: 16384)),
            JsonObjectEntry("workspaceFolders", folders())])
    }
    func folders(): JsonNode { jsonArray([jsonObject([JsonObjectEntry("uri", jsonString(rootUri)), JsonObjectEntry("name", jsonString("workspace"))])]) }
    func settingsValue(): JsonNode { parseUnifiedJson(settings, maxBytes: 16384) }
    func admitsUri(uri: String): Bool {
        uri != "" && uri.size <= 4096 && !uri.contains("\u{0000}") &&
            (uri == rootUri || uri.startsWith(if (rootUri.endsWith("/")) { rootUri } else { rootUri + "/" }))
    }
}
