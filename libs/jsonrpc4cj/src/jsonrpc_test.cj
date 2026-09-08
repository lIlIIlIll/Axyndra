package jsonrpc4cj

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonRpc4CjTests {
    @TestCase
    func legalIdsPreserveEncodingAndCorrelateExactly() {
        for (literal in ["1e3", "1000", "1.2500", "9007199254740993", "18446744073709551616", "-0", "1e999999999999999999999999999999"]) {
            let id = JsonRpcId(JsonRpcIdKind.Number, value: literal)
            let encoded = encodeJsonRpc(JsonRpcEnvelope.Request(JsonRpcRequest(id, "echo")))
            match (decodeJsonRpc(encoded)) {
                case JsonRpcResult.Ok(JsonRpcEnvelope.Request(request)) => @Expect(request.id.value, literal)
                case _ => @Fail("legal numeric ID must preserve its original JSON representation")
            }
        }
        let pairs = [("1e3", "1000"), ("1.2500", "125e-2"), ("-1.2500", "-125e-2"),
            ("1e+0003", "1000.0"), ("0.0001", "1e-4"), ("10e-1", "1"),
            ("9007199254740993000", "9007199254740993e3"),
            ("184467440737095516160", "18446744073709551616e1"),
            ("-0", "0.000e999999999999999999999"),
            ("1e999999999999999999999999", "10e999999999999999999999998"),
            ("0.1e-999999999999999999999998", "1e-999999999999999999999999"),
            ("10e999999999999999999999999", "1e1000000000000000000000000"),
            ("0.1e-999999999999999999999999", "1e-1000000000000000000000000")]
        for ((left, right) in pairs) {
            let correlation = JsonRpcCorrelation()
            let a = JsonRpcId(JsonRpcIdKind.Number, value: left)
            let b = JsonRpcId(JsonRpcIdKind.Number, value: right)
            @Expect(sameJsonRpcId(a, b), true)
            @Expect(correlation.reserve(a).isOk(), true)
            @Expect(correlation.reserve(b).isOk(), false)
            @Expect(correlation.complete(b).isOk(), true)
        }
        @Expect(sameJsonRpcId(JsonRpcId(JsonRpcIdKind.Number, value: "9007199254740992"),
            JsonRpcId(JsonRpcIdKind.Number, value: "9007199254740993")), false)
        for ((left, right) in [("1.25", "1.26"), ("-1", "1"), ("0", "1e-999999999999999999999999"),
            ("1e999999999999999999999999", "1e999999999999999999999998")]) {
            @Expect(sameJsonRpcId(JsonRpcId(JsonRpcIdKind.Number, value: left),
                JsonRpcId(JsonRpcIdKind.Number, value: right)), false)
        }
        @Expect(sameJsonRpcId(jsonRpcTextId("1000"), jsonRpcNumberId(1000)), false)
        @Expect(decodeJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"method\":\"echo\"}").isOk(), true)
        let emptyError = JsonRpcEnvelope.Response(JsonRpcResponse(jsonRpcTextId(""),
            JsonRpcResponsePayload.Failure(JsonRpcError(-1, ""))))
        @Expect(decodeJsonRpc(encodeJsonRpc(emptyError)).isOk(), true)
        for (invalid in ["", "01", "+1", "NaN", "Infinity", "1.", ".1", "1e", " 1", "1 "]) {
            var rejected = false
            try { let _ = JsonRpcId(JsonRpcIdKind.Number, value: invalid) }
            catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected, true)
        }
    }

    @TestCase
    func requestNotificationAndResponsesRoundTrip() {
        let request = JsonRpcEnvelope.Request(JsonRpcRequest(
            jsonRpcNumberId(7), "tools/call",
            params: jsonObject([JsonObjectEntry("name", jsonString("read"))])
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
            jsonRpcTextId("a"), JsonRpcResponsePayload.Success(jsonBool(true))
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
