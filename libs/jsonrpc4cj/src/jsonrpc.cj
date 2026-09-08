package jsonrpc4cj

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*

public let JSON_RPC_VERSION = "2.0"
public let JSON_RPC_PARSE_ERROR: Int64 = -32700
public let JSON_RPC_INVALID_REQUEST: Int64 = -32600
public let JSON_RPC_METHOD_NOT_FOUND: Int64 = -32601
public let JSON_RPC_INVALID_PARAMS: Int64 = -32602
public let JSON_RPC_INTERNAL_ERROR: Int64 = -32603

public enum JsonRpcProtocolErrorKind {
    Parse | InvalidRequest | IdInUse | RequestFinished | UnknownId
}

public class JsonRpcProtocolError {
    public let kind: JsonRpcProtocolErrorKind
    public let code: String
    public let message: String
    public let rpcCode: Int64
    public let requestId: String

    public init(
        kind: JsonRpcProtocolErrorKind,
        code: String,
        message: String,
        rpcCode!: Int64 = JSON_RPC_INVALID_REQUEST,
        requestId!: String = ""
    ) {
        this.kind = kind
        this.code = code
        this.message = message
        this.rpcCode = rpcCode
        this.requestId = requestId
    }
}

public enum JsonRpcResult<T> {
    Ok(T) | Err(JsonRpcProtocolError)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }

    public func value(): ?T {
        match (this) { case Ok(value) => Some(value); case Err(_) => None }
    }

    public func error(): ?JsonRpcProtocolError {
        match (this) { case Ok(_) => None; case Err(error) => Some(error) }
    }
}

public enum JsonRpcIdKind <: Equatable<JsonRpcIdKind> {
    Text | Number | Null

    public operator func ==(other: JsonRpcIdKind): Bool {
        match (this) {
            case Text => if (let Text <- other) { true } else { false }
            case Number => if (let Number <- other) { true } else { false }
            case Null => if (let Null <- other) { true } else { false }
        }
    }

    public operator func !=(other: JsonRpcIdKind): Bool { !(this == other) }
}

public class JsonRpcId {
    public let kind: JsonRpcIdKind
    public let value: String

    public init(kind: JsonRpcIdKind, value!: String = "") {
        match (kind) {
            case JsonRpcIdKind.Text => ()
            case JsonRpcIdKind.Number =>
                try {
                    let _ = jsonNumber(value)
                } catch (_: Exception) {
                    throw IllegalArgumentException("JSON-RPC number id must be a JSON number")
                }
            case JsonRpcIdKind.Null =>
                if (value != "") { throw IllegalArgumentException("JSON-RPC null id must not carry a value") }
        }
        this.kind = kind
        this.value = value
    }

    public func display(): String {
        match (kind) {
            case JsonRpcIdKind.Text => value
            case JsonRpcIdKind.Number => value
            case JsonRpcIdKind.Null => "null"
        }
    }
}

public func jsonRpcTextId(value: String): JsonRpcId {
    JsonRpcId(JsonRpcIdKind.Text, value: value)
}

public func jsonRpcNumberId(value: Int64): JsonRpcId {
    JsonRpcId(JsonRpcIdKind.Number, value: value.toString())
}

public func jsonRpcNullId(): JsonRpcId { JsonRpcId(JsonRpcIdKind.Null) }

public func sameJsonRpcId(left: JsonRpcId, right: JsonRpcId): Bool {
    if (left.kind != right.kind) { return false }
    if (left.kind == JsonRpcIdKind.Number) {
        normalizedJsonRpcNumber(left.value) == normalizedJsonRpcNumber(right.value)
    } else { left.value == right.value }
}

public class JsonRpcRequest {
    public let id: JsonRpcId
    public let method: String
    public let params: JsonNode

    public init(id: JsonRpcId, method: String, params!: JsonNode = jsonObject([])) {
        requireMethod(method)
        requireParams(params)
        this.id = id
        this.method = method
        this.params = params
    }
}

public class JsonRpcNotification {
    public let method: String
    public let params: JsonNode

    public init(method: String, params!: JsonNode = jsonObject([])) {
        requireMethod(method)
        requireParams(params)
        this.method = method
        this.params = params
    }
}

public class JsonRpcError {
    public let code: Int64
    public let message: String
    public let data: JsonNode

    public init(code: Int64, message: String, data!: JsonNode = jsonNull()) {
        this.code = code
        this.message = message
        this.data = data
    }
}

public enum JsonRpcResponsePayload {
    Success(JsonNode) | Failure(JsonRpcError)
}

public class JsonRpcResponse {
    public let id: JsonRpcId
    public let payload: JsonRpcResponsePayload

    public init(id: JsonRpcId, payload: JsonRpcResponsePayload) {
        this.id = id
        this.payload = payload
    }
}

public enum JsonRpcEnvelope {
    Request(JsonRpcRequest) | Notification(JsonRpcNotification) | Response(JsonRpcResponse)
}

public func encodeJsonRpc(envelope: JsonRpcEnvelope): String {
    stringifyUnifiedJson(jsonRpcValue(envelope))
}

public func jsonRpcValue(envelope: JsonRpcEnvelope): JsonNode {
    match (envelope) {
        case JsonRpcEnvelope.Request(request) =>
            jsonObject([
                JsonObjectEntry("jsonrpc", jsonString(JSON_RPC_VERSION)),
                JsonObjectEntry("id", jsonRpcIdValue(request.id)),
                JsonObjectEntry("method", jsonString(request.method)),
                JsonObjectEntry("params", request.params)
            ])
        case JsonRpcEnvelope.Notification(notification) =>
            jsonObject([
                JsonObjectEntry("jsonrpc", jsonString(JSON_RPC_VERSION)),
                JsonObjectEntry("method", jsonString(notification.method)),
                JsonObjectEntry("params", notification.params)
            ])
        case JsonRpcEnvelope.Response(response) => match (response.payload) {
            case JsonRpcResponsePayload.Success(result) => jsonObject([
                JsonObjectEntry("jsonrpc", jsonString(JSON_RPC_VERSION)),
                JsonObjectEntry("id", jsonRpcIdValue(response.id)),
                JsonObjectEntry("result", result)
            ])
            case JsonRpcResponsePayload.Failure(error) =>
                let fields = ArrayList<JsonObjectEntry>()
                fields.add(JsonObjectEntry("code", jsonNumber(error.code.toString())))
                fields.add(JsonObjectEntry("message", jsonString(error.message)))
                if (error.data.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("data", error.data)) }
                jsonObject([
                    JsonObjectEntry("jsonrpc", jsonString(JSON_RPC_VERSION)),
                    JsonObjectEntry("id", jsonRpcIdValue(response.id)),
                    JsonObjectEntry("error", jsonObject(fields.toArray()))
                ])
        }
    }
}

public func decodeJsonRpc(source: String, maxBytes!: Int64 = 8388608): JsonRpcResult<JsonRpcEnvelope> {
    let root = try {
        parseUnifiedJson(source, maxBytes: maxBytes)
    } catch (error: JsonException) {
        return failure<JsonRpcEnvelope>(
            JsonRpcProtocolErrorKind.Parse,
            "json_rpc.parse_error",
            error.message,
            rpcCode: JSON_RPC_PARSE_ERROR
        )
    }
    decodeJsonRpcValue(root)
}

public func decodeJsonRpcValue(root: JsonNode): JsonRpcResult<JsonRpcEnvelope> {
    if (root.unifiedKind != UnifiedJsonKind.Object) {
        return invalidRequest<JsonRpcEnvelope>("JSON-RPC message must be an object")
    }
    let version = match (root.field("jsonrpc")) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) {
            value.text
        } else {
            return invalidRequest<JsonRpcEnvelope>("jsonrpc must be the string 2.0")
        }
        case None => return invalidRequest<JsonRpcEnvelope>("jsonrpc must be the string 2.0")
    }
    if (version != JSON_RPC_VERSION) {
        return invalidRequest<JsonRpcEnvelope>("unsupported JSON-RPC version")
    }
    match (root.field("method")) {
        case Some(method) => decodeCall(root, method)
        case None => decodeResponse(root)
    }
}

func decodeCall(root: JsonNode, method: JsonNode): JsonRpcResult<JsonRpcEnvelope> {
    if (method.unifiedKind != UnifiedJsonKind.Text || method.text.trimAscii() == "") {
        return invalidRequest<JsonRpcEnvelope>("method must be a non-empty string")
    }
    if (root.field("result").isSome() || root.field("error").isSome()) {
        return invalidRequest<JsonRpcEnvelope>("request must not contain result or error")
    }
    let params = match (root.field("params")) {
        case Some(value) => value
        case None => jsonObject([])
    }
    if (params.unifiedKind != UnifiedJsonKind.Object && params.unifiedKind != UnifiedJsonKind.List) {
        return invalidRequest<JsonRpcEnvelope>("params must be an object or array")
    }
    match (root.field("id")) {
        case Some(value) => match (decodeJsonRpcId(value)) {
            case JsonRpcResult.Ok(id) => JsonRpcResult.Ok(JsonRpcEnvelope.Request(
                JsonRpcRequest(id, method.text, params: params)
            ))
            case JsonRpcResult.Err(error) => JsonRpcResult.Err(error)
        }
        case None => JsonRpcResult.Ok(JsonRpcEnvelope.Notification(
            JsonRpcNotification(method.text, params: params)
        ))
    }
}

func decodeResponse(root: JsonNode): JsonRpcResult<JsonRpcEnvelope> {
    let id = match (root.field("id")) {
        case Some(value) => match (decodeJsonRpcId(value)) {
            case JsonRpcResult.Ok(id) => id
            case JsonRpcResult.Err(error) => return JsonRpcResult.Err(error)
        }
        case None => return invalidRequest<JsonRpcEnvelope>("response id is required")
    }
    let result = root.field("result")
    let remoteError = root.field("error")
    if (result.isSome() == remoteError.isSome()) {
        return invalidRequest<JsonRpcEnvelope>("response must contain exactly one of result or error")
    }
    match (result) {
        case Some(value) => JsonRpcResult.Ok(JsonRpcEnvelope.Response(
            JsonRpcResponse(id, JsonRpcResponsePayload.Success(value))
        ))
        case None =>
            let value = remoteError.getOrThrow()
            if (value.unifiedKind != UnifiedJsonKind.Object) {
                return invalidRequest<JsonRpcEnvelope>("error must be an object")
            }
            let code = match (value.field("code")) {
                case Some(item) =>
                    if (item.unifiedKind != UnifiedJsonKind.Number) {
                        return invalidRequest<JsonRpcEnvelope>("error code must be an integer")
                    }
                    try {
                        Int64.parse(item.number)
                    } catch (_: Exception) {
                        return invalidRequest<JsonRpcEnvelope>("error code must be an integer")
                    }
                case None => return invalidRequest<JsonRpcEnvelope>("error code must be an integer")
            }
            let message = match (value.field("message")) {
                case Some(item) =>
                    if (item.unifiedKind != UnifiedJsonKind.Text) {
                        return invalidRequest<JsonRpcEnvelope>("error message must be a string")
                    }
                    item.text
                case None => return invalidRequest<JsonRpcEnvelope>("error message must be a string")
            }
            let data = match (value.field("data")) {
                case Some(item) => item
                case None => jsonNull()
            }
            JsonRpcResult.Ok(JsonRpcEnvelope.Response(JsonRpcResponse(
                id, JsonRpcResponsePayload.Failure(JsonRpcError(code, message, data: data))
            )))
    }
}

func decodeJsonRpcId(value: JsonNode): JsonRpcResult<JsonRpcId> {
    match (value.unifiedKind) {
        case UnifiedJsonKind.Text => try {
            JsonRpcResult.Ok(jsonRpcTextId(value.text))
        } catch (error: IllegalArgumentException) {
            invalidRequest<JsonRpcId>(error.message)
        }
        case UnifiedJsonKind.Number => try {
            JsonRpcResult.Ok(JsonRpcId(JsonRpcIdKind.Number, value: value.number))
        } catch (error: IllegalArgumentException) {
            invalidRequest<JsonRpcId>(error.message)
        }
        case UnifiedJsonKind.Null => JsonRpcResult.Ok(jsonRpcNullId())
        case _ => invalidRequest<JsonRpcId>("id must be a string, number, or null")
    }
}

func jsonRpcIdValue(id: JsonRpcId): JsonNode {
    match (id.kind) {
        case JsonRpcIdKind.Text => jsonString(id.value)
        case JsonRpcIdKind.Number => jsonNumber(id.value)
        case JsonRpcIdKind.Null => jsonNull()
    }
}

func requireMethod(method: String): Unit {
    if (method.trimAscii() == "") { throw IllegalArgumentException("JSON-RPC method must not be empty") }
}

func requireParams(params: JsonNode): Unit {
    if (params.unifiedKind != UnifiedJsonKind.Object && params.unifiedKind != UnifiedJsonKind.List) {
        throw IllegalArgumentException("JSON-RPC params must be an object or array")
    }
}

func invalidRequest<T>(message: String): JsonRpcResult<T> {
    failure<T>(JsonRpcProtocolErrorKind.InvalidRequest, "json_rpc.invalid_request", message)
}

func failure<T>(
    kind: JsonRpcProtocolErrorKind,
    code: String,
    message: String,
    rpcCode!: Int64 = JSON_RPC_INVALID_REQUEST,
    requestId!: String = ""
): JsonRpcResult<T> {
    JsonRpcResult.Err(JsonRpcProtocolError(
        kind, code, message, rpcCode: rpcCode, requestId: requestId
    ))
}

public enum JsonRpcPendingState <: Equatable<JsonRpcPendingState> {
    Pending | Completed | Cancelled

    public operator func ==(other: JsonRpcPendingState): Bool {
        match (this) {
            case Pending => if (let Pending <- other) { true } else { false }
            case Completed => if (let Completed <- other) { true } else { false }
            case Cancelled => if (let Cancelled <- other) { true } else { false }
        }
    }

    public operator func !=(other: JsonRpcPendingState): Bool { !(this == other) }
}

class JsonRpcPending {
    let id: JsonRpcId
    var state: JsonRpcPendingState

    init(id: JsonRpcId) {
        this.id = id
        this.state = JsonRpcPendingState.Pending
    }
}

public class JsonRpcCorrelation {
    private let values = ArrayList<JsonRpcPending>()
    private let lock = Mutex()

    public init() {}

    public func reserve(id: JsonRpcId): JsonRpcResult<Unit> {
        lock.lock()
        try {
            for (item in values where sameJsonRpcId(item.id, id)) {
                return failure<Unit>(
                    JsonRpcProtocolErrorKind.IdInUse,
                    "json_rpc.id_in_use",
                    "JSON-RPC id is already in use",
                    requestId: id.display()
                )
            }
            values.add(JsonRpcPending(id))
            JsonRpcResult.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func complete(id: JsonRpcId): JsonRpcResult<Unit> {
        transition(id, JsonRpcPendingState.Completed)
    }

    public func cancel(id: JsonRpcId): JsonRpcResult<Unit> {
        transition(id, JsonRpcPendingState.Cancelled)
    }

    public func state(id: JsonRpcId): ?JsonRpcPendingState {
        lock.lock()
        try {
            for (item in values where sameJsonRpcId(item.id, id)) { return Some(item.state) }
            None
        } finally {
            lock.unlock()
        }
    }

    public func pendingCount(): Int64 {
        lock.lock()
        try {
            var count: Int64 = 0
            for (item in values where item.state == JsonRpcPendingState.Pending) { count += 1 }
            count
        } finally {
            lock.unlock()
        }
    }

    public func release(id: JsonRpcId): Bool {
        lock.lock()
        try {
            for (index in 0..values.size) {
                if (sameJsonRpcId(values[index].id, id)) {
                    values.remove(at: index)
                    return true
                }
            }
            false
        } finally {
            lock.unlock()
        }
    }

    private func transition(id: JsonRpcId, next: JsonRpcPendingState): JsonRpcResult<Unit> {
        lock.lock()
        try {
            for (item in values where sameJsonRpcId(item.id, id)) {
                if (item.state != JsonRpcPendingState.Pending) {
                    return failure<Unit>(
                        JsonRpcProtocolErrorKind.RequestFinished,
                        "json_rpc.request_finished",
                        "JSON-RPC request is already finished",
                        requestId: id.display()
                    )
                }
                item.state = next
                return JsonRpcResult.Ok(())
            }
            failure<Unit>(
                JsonRpcProtocolErrorKind.UnknownId,
                "json_rpc.id_unknown",
                "JSON-RPC id is not pending",
                requestId: id.display()
            )
        } finally {
            lock.unlock()
        }
    }
}

// Compare exact decimal values without expanding powers of ten or rounding
// through floating point. The input was validated by JsonNumberLiteralValue.
func normalizedJsonRpcNumber(value: String): String {
    let bytes = value.toArray()
    let negative = bytes[0] == b'-'
    let start: Int64 = if (negative) { 1 } else { 0 }
    var exponentAt = bytes.size
    var fractionDigits: Int64 = 0
    var fractional = false
    let digits = ArrayList<Byte>()
    for (index in start..bytes.size) {
        let byte = bytes[index]
        if (byte == b'e' || byte == b'E') { exponentAt = index; break }
        if (byte == b'.') { fractional = true; continue }
        digits.add(byte)
        if (fractional) { fractionDigits += 1 }
    }
    var first: Int64 = 0
    while (first < digits.size && digits[first] == b'0') { first += 1 }
    if (first == digits.size) { return "0" }
    var end = digits.size
    while (end > first && digits[end - 1] == b'0') { end -= 1 }
    let exponent = if (exponentAt < bytes.size) {
        String.fromUtf8(bytes[(exponentAt + 1)..])
    } else { "0" }
    let adjusted = addJsonRpcExponent(exponent, digits.size - end - fractionDigits)
    let coefficientStart = first
    let coefficient = String.fromUtf8(Array<Byte>(end - first, { index => digits[coefficientStart + index] }))
    (if (negative) { "-" } else { "" }) + coefficient + "e" + adjusted
}

func jsonRpcUnsignedDigits(value: String): String {
    let bytes = value.toArray()
    var first: Int64 = if (bytes[0] == b'-' || bytes[0] == b'+') { 1 } else { 0 }
    while (first < bytes.size - 1 && bytes[first] == b'0') { first += 1 }
    String.fromUtf8(bytes[first..])
}

func addJsonRpcExponent(value: String, adjustment: Int64): String {
    let left = jsonRpcUnsignedDigits(value)
    let right = jsonRpcUnsignedDigits(adjustment.toString())
    let leftNegative = value.startsWith("-") && left != "0"
    let rightNegative = adjustment < 0
    if (leftNegative == rightNegative) {
        let sum = jsonRpcMagnitudeArithmetic(left, right, false)
        return (if (leftNegative && sum != "0") { "-" } else { "" }) + sum
    }
    var leftGreater = left.size > right.size
    if (left.size == right.size) {
        let a = left.toArray()
        let b = right.toArray()
        for (index in 0..a.size) {
            if (a[index] != b[index]) { leftGreater = a[index] > b[index]; break }
        }
    }
    if (left == right) { return "0" }
    let difference = if (leftGreater) {
        jsonRpcMagnitudeArithmetic(left, right, true)
    } else { jsonRpcMagnitudeArithmetic(right, left, true) }
    let negative = if (leftGreater) { leftNegative } else { rightNegative }
    (if (negative) { "-" } else { "" }) + difference
}

// Addition, or subtraction where the left magnitude is greater than the right.
func jsonRpcMagnitudeArithmetic(left: String, right: String, subtract: Bool): String {
    let a = left.toArray()
    let b = right.toArray()
    let reversed = ArrayList<Byte>()
    var offset: Int64 = 0
    var carry: Int64 = 0
    while (offset < a.size || offset < b.size) {
        let x: Int64 = if (offset < a.size) { Int64(a[a.size - 1 - offset] - b'0') } else { 0 }
        let y: Int64 = if (offset < b.size) { Int64(b[b.size - 1 - offset] - b'0') } else { 0 }
        var digit = if (subtract) { x - y - carry } else { x + y + carry }
        if (subtract) {
            carry = if (digit < 0) { 1 } else { 0 }
            if (digit < 0) { digit += 10 }
        } else {
            carry = digit / 10
            digit %= 10
        }
        reversed.add(UInt8(digit) + b'0')
        offset += 1
    }
    if (carry > 0) { reversed.add(UInt8(carry) + b'0') }
    while (reversed.size > 1 && reversed[reversed.size - 1] == b'0') {
        reversed.remove(at: reversed.size - 1)
    }
    String.fromUtf8(Array<Byte>(reversed.size, { index => reversed[reversed.size - 1 - index] }))
}
