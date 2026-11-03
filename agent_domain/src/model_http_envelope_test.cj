package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func modelEnvelopeRequest(): AgentValue { objectValue([
    ValueField("method", textValue("POST")), ValueField("url", textValue("https://example.com/v1/messages")),
    ValueField("headers", objectValue([])), ValueField("body_hex", textValue("7b7d")),
    ValueField("credential_refs", listValue([])), ValueField("timeout_ms", integerValue(1000)),
    ValueField("max_response_bytes", integerValue(modelHttpWireMaximum(8388608)))]) }

@Test
class ModelHttpEnvelopeTests {
    @TestCase
    func ordinaryHttpRetainsItsCeilingAndModelAllowanceIsExact(): Unit {
        let request = modelEnvelopeRequest()
        @Expect(validateHttpStreamRequest(request, responseBytes: 8388608).isError())
        @Expect(validateHttpStreamRequest(request, responseBytes: 8454144).isError())
        @Expect(validateHttpStreamRequest(request, responseBytes: 8454144, modelEnvelope: true).isOk())
        request.put("max_response_bytes", integerValue(8454145))
        @Expect(validateHttpStreamRequest(request, responseBytes: 8454144, modelEnvelope: true).isError())
        @Expect(validateHttpStreamRequest(request, responseBytes: 8454145, modelEnvelope: true).isError())
        @Expect(modelHttpWireMaximum(8388608), 8454144)
    }
    @TestCase
    func envelopeCannotRelaxEndpointCredentialsOrCanonicalLimits(): Unit {
        for (mode in ["url", "header", "credential", "time", "body"]) {
            let request = modelEnvelopeRequest()
            if (mode == "url") { request.put("url", textValue("http://user:secret@example.com/v1/messages")) }
            if (mode == "header") { request.put("headers", objectValue([ValueField("authorization", textValue("caller secret"))])) }
            if (mode == "credential") { request.put("credential_refs", listValue([textValue("x"), textValue("x")])) }
            if (mode == "time") { request.put("timeout_ms", integerValue(-1)) }
            if (mode == "body") { request.put("body_hex", textValue("not-hex")) }
            @Expect(validateHttpStreamRequest(request, responseBytes: 8454144, modelEnvelope: true).isError())
        }
    }
}
