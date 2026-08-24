package jsonrpc4cj

import json4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonRpc4CjTests {
    @TestCase
    func requestNotificationAndResponsesRoundTrip() {
        let request = JsonRpcEnvelope.Request(JsonRpcRequest(
            jsonRpcNumberId(7), "tools/call",
            params: JsonValue.objectValue([JsonField("name", JsonValue.stringValue("read"))])
        ))
        match (decodeJsonRpc(encodeJsonRpc(request))) {
            case JsonRpcResult.Ok(JsonRpcEnvelope.Request(value)) =>
                @Expect(value.method, "tools/call")
                @Expect(value.id.value, "7")
            case _ => @Fail("request did not round-trip")
        }

        match (decodeJsonRpc("{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}")) {
            case JsonRpcResult.Ok(JsonRpcEnvelope.Notification(value)) => @Expect(value.method, "ready")
            case _ => @Fail("notification did not decode")
        }

        let success = JsonRpcEnvelope.Response(JsonRpcResponse(
            jsonRpcTextId("a"), JsonRpcResponsePayload.Success(JsonValue.boolValue(true))
        ))
        @Expect(decodeJsonRpc(encodeJsonRpc(success)).isOk(), true)

        let remoteError = JsonRpcEnvelope.Response(JsonRpcResponse(
            jsonRpcTextId("b"),
            JsonRpcResponsePayload.Failure(JsonRpcError(-32000, "remote failure"))
        ))
        @Expect(decodeJsonRpc(encodeJsonRpc(remoteError)).isOk(), true)
    }

    @TestCase
    func rejectsInvalidEnvelopes() {
        expectErrorCode(decodeJsonRpc("{not-json"), JSON_RPC_PARSE_ERROR)
        expectErrorCode(decodeJsonRpc("[]"), JSON_RPC_INVALID_REQUEST)
        expectErrorCode(decodeJsonRpc(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}"
        ), JSON_RPC_INVALID_REQUEST)
        expectErrorCode(decodeJsonRpc(
            "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"x\"}"
        ), JSON_RPC_INVALID_REQUEST)
    }

    @TestCase
    func correlatesAndCancelsExactlyOnce() {
        let correlation = JsonRpcCorrelation()
        let id = jsonRpcTextId("request-1")
        @Expect(correlation.reserve(id).isOk(), true)
        @Expect(correlation.reserve(id).isOk(), false)
        @Expect(correlation.cancel(id).isOk(), true)
        @Expect(correlation.cancel(id).isOk(), false)
        @Expect(correlation.state(id).getOrThrow() == JsonRpcPendingState.Cancelled, true)
        @Expect(correlation.pendingCount(), 0)
        @Expect(correlation.release(id), true)
        @Expect(correlation.complete(id).isOk(), false)
    }
}

func expectErrorCode(result: JsonRpcResult<JsonRpcEnvelope>, expected: Int64): Unit {
    match (result) {
        case JsonRpcResult.Err(error) => @Expect(error.rpcCode, expected)
        case JsonRpcResult.Ok(_) => @Fail("expected JSON-RPC protocol error")
    }
}
