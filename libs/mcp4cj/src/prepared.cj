package mcp4cj

import jsonrpc4cj.*
import yjson.*
import yjson_support.*

let MCP_PREPARED_REQUEST_MAX_BYTES: Int64 = 8388608
let MCP_PREPARED_DISPATCH_LIMIT: Int64 = 4096

// A library-session seal, not a host authorization capability.
class McpPreparedClientSeal {}
class McpPreparedHttpSeal {}

// An immutable transport snapshot, not permission to use a host HTTP service.
class McpPreparedHttpRequest {
    let seal: McpPreparedHttpSeal
    let request: McpHttpExchangeRequest
    init(seal: McpPreparedHttpSeal, request: McpHttpExchangeRequest) {
        this.seal = seal; this.request = request
    }
}

// Only McpClient creates this immutable value. Mutable JsonNode input and tool
// metadata never escape into the approval artifact or the execution path.
public class McpPreparedToolCall {
    public let requestId: String
    public let rpcJson: String
    private let clientSeal: McpPreparedClientSeal
    private let toolJson: String
    let owner: String
    private let http: ?McpPreparedHttpRequest

    // No I/O, handle, credential lookup or mutable schema escapes here.
    // Standalone callers supplying literal HTTP credentials retain their old
    // configuration behavior; broker plugins must use opaque host references.
    public prop httpExchange: ?McpHttpExchangeRequest {
        get() { match (http) { case Some(value) => Some(value.request); case None => None } }
    }

    init(seal: McpPreparedClientSeal, requestId: String, rpcJson: String,
        toolJson: String, owner: String, http!: ?McpPreparedHttpRequest = None) {
        this.clientSeal = seal
        this.requestId = requestId
        this.rpcJson = rpcJson
        this.toolJson = toolJson
        this.owner = owner
        this.http = http
    }

    // Returns a new array. Framing adds exactly one LF, without rewriting JSON.
    public func stdioFrame(): Array<Byte> { (rpcJson + "\n").toArray() }

    func belongsTo(seal: McpPreparedClientSeal): Bool { refEq(clientSeal, seal) }

    func withHttp(seal: McpPreparedHttpSeal, request: McpHttpExchangeRequest): McpPreparedToolCall {
        McpPreparedToolCall(clientSeal, requestId, rpcJson, toolJson, owner,
            http: Some(McpPreparedHttpRequest(seal, request)))
    }

    func httpFor(seal: McpPreparedHttpSeal): ?McpHttpExchangeRequest {
        match (http) {
            case Some(value) => if (refEq(value.seal, seal)) { Some(value.request) } else { None }
            case None => None
        }
    }

    func request(): JsonRpcRequest {
        match (decodeJsonRpc(rpcJson, maxBytes: MCP_PREPARED_REQUEST_MAX_BYTES)) {
            case JsonRpcResult.Ok(JsonRpcEnvelope.Request(value)) => value
            case _ => throw IllegalStateException("invalid internal prepared MCP request")
        }
    }

    func tool(): ?McpTool {
        if (toolJson == "") { return None }
        match (decodeMcpTool(parseUnifiedJson(toolJson, maxBytes: MCP_PREPARED_REQUEST_MAX_BYTES))) {
            case McpResult.Ok(value) => Some(value)
            case McpResult.Err(_) => throw IllegalStateException("invalid internal prepared MCP descriptor")
        }
    }
}

func validMcpPreparedRequestId(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 256) { return false }
    for (byte in bytes where byte < 33 || byte > 126) { return false }
    true
}
