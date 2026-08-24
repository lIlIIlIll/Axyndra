package agent_mcp

import agent_domain.*
import agent_protocol.*

public interface McpTransport {
    func kind(): McpTransportKind
    func state(): McpLifecycleState
    func request(request: JsonRpcRequest): Result<JsonRpcResponse>
    func notify(notification: JsonRpcNotification): Result<Unit>
    func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): Result<Unit>
    func close(): Result<Unit>
}

// Native transport implementations wire these protocol-owned operations to
// std.process pipes or stdx.net.http. They must never route stdio through a
// one-shot shell/process executor.
public class McpNativeTransportWiring {
    public let stdioRead: String
    public let stdioWrite: String
    public let stdioLogs: String
    public let httpRequest: String
    public let httpSubscription: String

    public init() {
        stdioRead = "process4cj stdout line channel -> McpJsonLineFramer -> decodeJsonRpc"
        stdioWrite = "thread-safe encodeJsonRpc writer -> process4cj input lifecycle"
        stdioLogs = "bounded process4cj stderr reader; stdout is protocol-only"
        httpRequest = "stdx.net.http POST /mcp; JSON or Streamable HTTP SSE response"
        httpSubscription = "not advertised by the core transport"
    }
}

public func mcpCancellationNotification(
    requestId: JsonRpcId,
    reason: String,
    meta: McpRequestMeta
): JsonRpcNotification {
    let _ = meta
    JsonRpcNotification(
        MCP_METHOD_CANCELLED,
        params: objectValue([
            ValueField("requestId", mcpRequestIdValue(requestId)),
            ValueField("reason", textValue(reason))
        ])
    )
}

func mcpRequestIdValue(id: JsonRpcId): AgentValue {
    match (id.kind) {
        case JsonRpcIdKind.Text => textValue(id.value)
        case JsonRpcIdKind.Number => numberValue(id.value)
        case JsonRpcIdKind.Null => nullValue()
    }
}

func mcpFailure<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    retryable!: Bool = false,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(AgentError(kind, code, message, retryable: retryable, fields: fields))
}
