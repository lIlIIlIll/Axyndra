package dap_plugin

import yjson.*
import yjson_support.*

class DapConfiguration {
    let adapterId: String
    let timeoutMillis: Int64
    private let options: String
    init(value: JsonNode, limits: ProtocolLimits) {
        exact(value, ["version", "adapter_id", "initialization", "request_timeout_ms"])
        require(number(value, "version") == 1 && field(value, "version").asNumberText() == "1", "dap_plugin.configuration_version")
        let adapter = text(value, "adapter_id")
        require(adapter != "" && adapter.size <= 128 && !adapter.contains("\u{0000}"), "dap_plugin.configuration_invalid")
        require(field(value, "initialization").unifiedKind == UnifiedJsonKind.Object, "dap_plugin.configuration_invalid")
        let timeout = number(value, "request_timeout_ms")
        require(timeout >= 1 && timeout <= limits.timeout, "dap_plugin.configuration_timeout")
        let encoded = stringifyUnifiedJson(value); require(encoded.size <= 16384, "dap_plugin.configuration_limit")
        adapterId = adapter; timeoutMillis = timeout; options = stringifyUnifiedJson(field(value, "initialization"))
    }
    func initialization(): JsonNode {
        let result = parseUnifiedJson(options, maxBytes: 16384)
        result.put("adapterID", jsonString(adapterId)); result.put("clientID", jsonString("axyndra-dap-plugin"))
        result.put("pathFormat", jsonString("path")); result.put("linesStartAt1", jsonBool(true)); result.put("columnsStartAt1", jsonBool(true))
        // A reverse process launch has no separately admitted host operation.
        result.put("supportsRunInTerminalRequest", jsonBool(false))
        result
    }
}
