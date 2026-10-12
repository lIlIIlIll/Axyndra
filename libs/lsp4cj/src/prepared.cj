package lsp4cj

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

class LspPreparedClientSeal {}

// A data-only notification. Each access decodes an independent value.
public class LspNotification {
    public let method: String
    private let encodedParams: String
    public init(method: String, params: JsonNode) {
        if (!lspPreparedIdentifier(method)) { throw IllegalArgumentException("invalid LSP notification method") }
        this.method = method
        encodedParams = stringifyUnifiedJson(params)
        let _ = parseUnifiedJson(encodedParams, maxBytes: 8388608, maxDepth: 128)
    }
    func message(): JsonNode { jsonObject([JsonObjectEntry("jsonrpc", jsonString("2.0")),
        JsonObjectEntry("method", jsonString(method)),
        JsonObjectEntry("params", parseUnifiedJson(encodedParams, maxBytes: 8388608, maxDepth: 128))]) }
}

// Only the live library client mints this immutable transport snapshot. The
// caller must separately submit these bytes to its real host admission path.
public class LspPreparedRequest {
    public let requestId: String
    public let expectsResponse: Bool
    public let requestJson: String
    private let seal: LspPreparedClientSeal
    private let frame: Array<Byte>
    init(seal: LspPreparedClientSeal, requestId: String, method: String, params: JsonNode,
        notifications: Array<LspNotification>) {
        if (!lspPreparedIdentifier(requestId) || (method != "" && !lspPreparedIdentifier(method)) ||
            notifications.size > 128 || (method == "" && notifications.isEmpty())) {
            throw IllegalArgumentException("invalid prepared LSP exchange")
        }
        let expects = method != ""
        let bytes = ArrayList<Byte>()
        for (notification in notifications) {
            let next = encodeLspMessage(notification.message())
            if (next.size > 8388608 - bytes.size) { throw IllegalArgumentException("prepared LSP exchange exceeds its bound") }
            bytes.add(all: next)
        }
        let encodedRequest = if (expects) { stringifyUnifiedJson(jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")), JsonObjectEntry("id", jsonString(requestId)),
            JsonObjectEntry("method", jsonString(method)), JsonObjectEntry("params", params)])) } else { "" }
        if (expects) {
            let value = parseUnifiedJson(encodedRequest, maxBytes: 8388608, maxDepth: 128)
            let next = encodeLspMessage(value)
            if (next.size > 8388608 - bytes.size) { throw IllegalArgumentException("prepared LSP exchange exceeds its bound") }
            bytes.add(all: next)
        }
        this.seal = seal; this.requestId = requestId; expectsResponse = expects
        requestJson = encodedRequest; frame = bytes.toArray()
    }
    public func framedBytes(): Array<Byte> { frame.clone() }
    func belongsTo(value: LspPreparedClientSeal): Bool { refEq(seal, value) }
}

func lspPreparedIdentifier(value: String): Bool {
    if (value == "" || value.size > 256) { return false }
    for (byte in value.toArray() where byte < 33u8 || byte > 126u8) { return false }
    true
}
func lspPendingKey(value: JsonNode): String {
    if (value.unifiedKind == UnifiedJsonKind.Text && lspPreparedIdentifier(value.text)) { return stringifyUnifiedJson(value) }
    if (value.unifiedKind == UnifiedJsonKind.Number) {
        let number = try { Int64.parse(value.asNumberText()) } catch (_: Exception) { -1 }
        if (number >= 0 && number.toString() == value.asNumberText()) { return value.asNumberText() }
    }
    ""
}
