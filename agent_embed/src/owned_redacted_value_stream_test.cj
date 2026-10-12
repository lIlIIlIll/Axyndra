package agent_embed

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

private class OwnedRedactionSmallOutput {
    var value = ""
    func write(part: String): Result<Unit> { value += part; Result.Ok(()) }
}
private class OwnedRedactionLargeOutput {
    let hash = SHA256()
    var maximum: Int64 = 0
    var bytes: Int64 = 0
    var chunks: Int64 = 0
    func write(part: String): Result<Unit> {
        maximum = max(maximum, part.size); bytes += part.size; chunks++
        @Expect(String.fromUtf8(part.toArray()), part)
        hash.write(part.toArray()); Result.Ok(())
    }
}
private class OwnedRedactionGuard { var calls: Int64 = 0; var output: Int64 = 0 }

@Test
class OwnedRedactedValueStreamTests {
    @TestCase
    func OrderedAllMarkersAndMalformedEmbeddedJsonMatchOriginalCompleteRedactor(): Unit {
        let values = [
            "plain 雪🙂\n\r\t\u{0} \\\"",
            "{\"api_key\":\"abc\\\"tail\",\"token\":[1,2],\"password\":null}",
            "\"token\" distant text : \"[REDACTED] token=abcd\" end",
            "\"apiKey\" no colon here",
            "Authorization: bearer fake\r\nCookie: abc\nSet-Cookie: xyz",
            "api_key= password=&token=abcd] access_token=abc def",
            "sk-a sk-ab sk-abc sk-abcd ghp_1234 github_pat_1234 xoxb-abcd xoxp-abcd",
            "-----BEGIN PRIVATE KEY-----abc-----END PRIVATE KEY-----tail-----BEGIN missing",
            "http://user:password@host/a https://second:password@host",
            "http://user@host https://secret:password@host",
            "http://user:password no at sign",
            "Authorization: token=abc\napi_key=sk-abcd & http://user:pass@host",
            "\"AWS_ACCESS_KEY_ID\":  abc, \"AWS_SECRET_ACCESS_KEY\":\"abc\""
        ]
        for (value in values) {
            let output = OwnedRedactionSmallOutput()
            @Expect(writeOwnedRedactedAgentValue(textValue(value),
                { part => output.write(part) }, { => Result.Ok(()) }).isOk(), true)
            @Expect(output.value, encodeAgentValue(textValue(defaultJsonTextRedaction(value))))
            output.value = ""
        }
    }
    @TestCase
    func ExactSensitiveFieldNamesAndCompleteNestedKindsMatchOriginalDocumentOrder(): Unit {
        let fields = ["token", "prefixTOKEN", "X-Api-Key", "a_p_i_k_e_y", "private_key",
            "PrivateKey", "a-password-x", "passwd", "tok_en", "token___", "token___x", "a-tokenish",
            "normal", "雪🙂", "not_secretly_safe"]
        let output = OwnedRedactionSmallOutput()
        for (name in fields) {
            let value = objectValue([ValueField(name, listValue([textValue("sk-abcd"),
                numberValue("-12.50e+02"), boolValue(true), nullValue(), objectValue([])])),
                ValueField("second", textValue("complete 雪🙂"))])
            @Expect(writeOwnedRedactedAgentValue(value, { part => output.write(part) },
                { => Result.Ok(()) }).isOk(), true)
            @Expect(output.value, encodeAgentValue(redactJsonAgentValue(value)))
            output.value = ""
        }
    }
    @TestCase
    func ActualPaidNearEightMiBNulRowStreamsAllFortyEightMiBWithCompleteHash(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let paid = pool.acquire(8388600)
        paid.ensureRetainedPeak(8388600 * 8 + 1048576)
        var value: ?AgentValue = None
        let output = OwnedRedactionLargeOutput()
        try {
            value = Some(textValue(String.fromUtf8(Array<Byte>(8388600, repeat: 0)) + "雪🙂"))
            @Expect(writeOwnedRedactedAgentValue(value.getOrThrow(), { part => output.write(part) },
                { => Result.Ok(()) }).isOk(), true)
            let expected = SHA256(); expected.write("\"".toArray())
            let block = String.fromUtf8(Array<Byte>(65536 * 6, { index => "\\u0000"[index % 6] })).toArray()
            for (_ in 0..127) { expected.write(block) }
            expected.write(String.fromUtf8(Array<Byte>((8388600 - 127 * 65536) * 6,
                { index => "\\u0000"[index % 6] })).toArray())
            expected.write("雪🙂\"".toArray())
            @Expect(logicalJsonEncodeHex(output.hash.finish()), logicalJsonEncodeHex(expected.finish()))
            @Expect(output.bytes, 8388600 * 6 + "雪🙂".size + 2)
            @Expect(output.maximum <= 16384 && output.chunks > 3000, true)
            @Expect(pool.usage()[1] > 67100000, true)
        } finally { value = None; paid.close() }
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func CompleteCredentialDenseScalarRemainsFixedChunksAndMatchesAllPasses(): Unit {
        let output = OwnedRedactionLargeOutput()
        // Repeated empty assignments EXPAND under the old redactor. No
        // output-size assumption derived only from input bytes is permitted.
        let unit = "token= &api_key= &sk-abcd &雪🙂\n"
        let count: Int64 = 8192
        let raw = String.fromUtf8(Array<Byte>(unit.size * count, { index => unit[index % unit.size] }))
        @Expect(writeOwnedRedactedAgentValue(textValue(raw), { part => output.write(part) },
            { => Result.Ok(()) }).isOk(), true)
        let oracle = encodeAgentValue(textValue(defaultJsonTextRedaction(raw)))
        let expected = SHA256(); expected.write(oracle.toArray())
        @Expect(logicalJsonEncodeHex(output.hash.finish()), logicalJsonEncodeHex(expected.finish()))
        @Expect(output.bytes, oracle.size); @Expect(output.maximum <= 16384, true)
    }
    @TestCase
    func FullUrlLookaheadKeepsFirstNoColonAuthoritySemanticsWithoutTailRetention(): Unit {
        let output = OwnedRedactionLargeOutput()
        let tail = String.fromUtf8(Array<Byte>(1048576, repeat: b'x'))
        let value = "http://" + tail + "@host https://user:password@host"
        @Expect(writeOwnedRedactedAgentValue(textValue(value), { part => output.write(part) },
            { => Result.Ok(()) }).isOk(), true)
        let expected = SHA256(); expected.write(encodeAgentValue(textValue(value)).toArray())
        @Expect(logicalJsonEncodeHex(output.hash.finish()), logicalJsonEncodeHex(expected.finish()))
        @Expect(output.maximum <= 16384, true)
    }
    @TestCase
    func CancellationDuringDiscardedSecretStopsBeforeFirstOutputAndPreservesTypedError(): Unit {
        let state = OwnedRedactionGuard()
        let value = "Authorization:" + String.fromUtf8(Array<Byte>(1048576, repeat: b'x'))
        let result = writeOwnedRedactedAgentValue(textValue(value), { _ => state.output++; Result.Ok(()) },
            { => state.calls++
                if (state.calls >= 8) { Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                    "test.redaction_cancelled", "actual guard denied")) } else { Result.Ok(()) } })
        @Expect(result.isOk(), false); @Expect(state.output, 0)
        match (result) { case Result.Err(error) => @Expect(error.code, "test.redaction_cancelled")
            case Result.Ok(_) => @Expect(false, true) }
    }
    @TestCase
    func RawRpcWriterKeepsSecretsAndAllNestedValuesExactly(): Unit {
        let value = objectValue([ValueField("token", textValue("sk-abcd\n雪🙂")),
            ValueField("number", numberValue("1.200e+30")), ValueField("nested", listValue([nullValue(), boolValue(false)]))])
        let output = OwnedRedactionSmallOutput()
        @Expect(writeOwnedUnredactedAgentValue(value, { part => output.write(part) },
            { => Result.Ok(()) }).isOk(), true)
        @Expect(output.value, encodeAgentValue(value)); output.value = ""
    }
}
