package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func logicalScalarArraySource(items: Int64): String {
    let bytes = Array<Byte>(items * 2 + 1, repeat: b'0')
    bytes[0] = b'['; bytes[bytes.size - 1] = b']'
    for (index in 0..items - 1) { bytes[index * 2 + 2] = b',' }
    String.fromUtf8(bytes)
}

@Test
class LogicalJsonScalarNodeTests {
    @TestCase
    func everyScalarAndMixedEscapedTreeMatchesTheExistingDomCounter(): Unit {
        for (source in ["null", "true", "false", "0", "-2.5e+3", "\"雪\"", "[]", "{}",
            "[null,true,false,0,-2.5e+3,\"雪\"]",
            "{\"escaped\\\"key\":\"\\\"\\\\[]{}:,\",\"nested\":[null,{\"a\":true},[]]}",
            " \t{\"a\": [false, -1, {\"b\": null}]}\r\n"]) {
            let actual = parseUnifiedJson(source, maxBytes: 1048576, maxDepth: 64)
            @Expect(logicalJsonNodeCount(source), logicalJsonValueNodeCount(actual))
        }
        @Expect(logicalJsonNodeCount("null"), 1)
        @Expect(logicalJsonNodeCount("[0]"), 2)
        @Expect(logicalJsonNodeCount("{\"a\":0}"), 3)
    }
    @TestCase
    func lastArrayScalarFitsExactlyAndTheNextNodeIsRefusedBeforeDecode(): Unit {
        let exact = logicalScalarArraySource(65535)
        @Expect(logicalJsonNodeCount(exact), 65536)
        @Expect(logicalJsonValueNodeCount(parseUnifiedJson(exact, maxBytes: 1048576, maxDepth: 64)), 65536)
        var refused = false
        try { let _ = logicalJsonNodeCount(logicalScalarArraySource(65536)) }
        catch (_: LogicalJsonPayloadError) { refused = true }
        @Expect(refused)
    }
    @TestCase
    func lexicalAccountingDoesNotReplaceTheOriginalSyntaxAndDepthParser(): Unit {
        for (source in ["nul", "truefalse", "[null,]", "{\"a\":01}", "\"unfinished"]) {
            let _ = logicalJsonNodeCount(source)
            var refused = false
            try { let _ = parseUnifiedJson(source, maxBytes: 1048576, maxDepth: 64) }
            catch (_: Exception) { refused = true }
            @Expect(refused)
        }
        let bytes = Array<Byte>(131, repeat: b'[')
        bytes[65] = b'0'
        for (index in 66..131) { bytes[index] = b']' }
        let nested = String.fromUtf8(bytes)
        @Expect(logicalJsonNodeCount(nested), 66)
        var refused = false
        try { let _ = parseUnifiedJson(nested, maxBytes: 1048576, maxDepth: 64) }
        catch (_: Exception) { refused = true }
        @Expect(refused)
    }
}
