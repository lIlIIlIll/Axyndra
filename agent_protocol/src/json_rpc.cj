package agent_protocol

import agent_domain.*
import jsonrpc4cj as library

public let JSON_RPC_VERSION = library.JSON_RPC_VERSION
public let JSON_RPC_PARSE_ERROR: Int64 = library.JSON_RPC_PARSE_ERROR
public let JSON_RPC_INVALID_REQUEST: Int64 = library.JSON_RPC_INVALID_REQUEST
public let JSON_RPC_METHOD_NOT_FOUND: Int64 = library.JSON_RPC_METHOD_NOT_FOUND
public let JSON_RPC_INVALID_PARAMS: Int64 = library.JSON_RPC_INVALID_PARAMS
public let JSON_RPC_INTERNAL_ERROR: Int64 = library.JSON_RPC_INTERNAL_ERROR

public type JsonRpcIdKind = library.JsonRpcIdKind
public type JsonRpcId = library.JsonRpcId
public type JsonRpcRequest = library.JsonRpcRequest
public type JsonRpcNotification = library.JsonRpcNotification
public type JsonRpcError = library.JsonRpcError
public type JsonRpcResponsePayload = library.JsonRpcResponsePayload
public type JsonRpcResponse = library.JsonRpcResponse
public type JsonRpcEnvelope = library.JsonRpcEnvelope
public type JsonRpcPendingState = library.JsonRpcPendingState

public func jsonRpcTextId(value: String): JsonRpcId { library.jsonRpcTextId(value) }

public func jsonRpcNumberId(value: Int64): JsonRpcId { library.jsonRpcNumberId(value) }

public func jsonRpcNullId(): JsonRpcId { library.jsonRpcNullId() }

public func sameJsonRpcId(left: JsonRpcId, right: JsonRpcId): Bool {
    library.sameJsonRpcId(left, right)
}

public func encodeJsonRpc(envelope: JsonRpcEnvelope): String { library.encodeJsonRpc(envelope) }

public func jsonRpcValue(envelope: JsonRpcEnvelope): AgentValue { library.jsonRpcValue(envelope) }

public func decodeJsonRpc(
    source: String,
    maxBytes!: Int64 = 8388608
): Result<JsonRpcEnvelope> {
    adaptJsonRpcResult(library.decodeJsonRpc(source, maxBytes: maxBytes))
}

public func decodeJsonRpcValue(root: AgentValue): Result<JsonRpcEnvelope> {
    adaptJsonRpcResult(library.decodeJsonRpcValue(root))
}

public class JsonRpcCorrelation {
    private let inner = library.JsonRpcCorrelation()

    public init() {}

    public func reserve(id: JsonRpcId): Result<Unit> { adaptJsonRpcResult(inner.reserve(id)) }

    public func complete(id: JsonRpcId): Result<Unit> { adaptJsonRpcResult(inner.complete(id)) }

    public func cancel(id: JsonRpcId): Result<Unit> { adaptJsonRpcResult(inner.cancel(id)) }

    public func state(id: JsonRpcId): ?JsonRpcPendingState { inner.state(id) }

    public func pendingCount(): Int64 { inner.pendingCount() }

    public func release(id: JsonRpcId): Bool { inner.release(id) }
}

func adaptJsonRpcResult<T>(result: library.JsonRpcResult<T>): Result<T> {
    match (result) {
        case library.JsonRpcResult.Ok(value) => Result.Ok(value)
        case library.JsonRpcResult.Err(error) => Result.Err(jsonRpcAgentError(error))
    }
}

func jsonRpcAgentError(error: library.JsonRpcProtocolError): AgentError {
    let kind = match (error.kind) {
        case library.JsonRpcProtocolErrorKind.IdInUse => AgentErrorKind.Conflict
        case library.JsonRpcProtocolErrorKind.RequestFinished => AgentErrorKind.Conflict
        case library.JsonRpcProtocolErrorKind.UnknownId => AgentErrorKind.InvalidInput
        case _ => AgentErrorKind.Protocol
    }
    let fields = if (error.requestId == "") {
        [ErrorField("json_rpc_code", error.rpcCode.toString())]
    } else {
        [
            ErrorField("json_rpc_code", error.rpcCode.toString()),
            ErrorField("id", error.requestId)
        ]
    }
    AgentError(kind, error.code, error.message, fields: fields)
}
