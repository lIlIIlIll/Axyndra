package agent_product

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelHttpMetadataTests {
    @TestCase
    func retryAfterIsBoundedAndOtherPrivateHeadersStayUnprojected(): Unit {
        let parser = ProductHttpExchangeHeadParser()
        let head = parser.push(("HTTP/1.1 429 Limited\r\nRetry-After: 2\r\nContent-Type: application/json\r\n" +
            "Set-Cookie: PRIVATE\r\nLocation: PRIVATE\r\nContent-Length: 0\r\n\r\n").toArray()).value().getOrThrow().getOrThrow()
        @Expect(head.retryAfter, "2")
        @Expect(head.contentType, "application/json")
        @Expect(head.status, 429)
        @Expect(ProductHttpExchangeOutputGate(["2"], maxBytes: 1024).push(head.retryAfter.toArray(), eof: true).isError())
    }
    @TestCase
    func duplicateOrControlRetryAfterIsRejectedBeforePublication(): Unit {
        for (value in ["Retry-After: 1\r\nRetry-After: 2\r\n", "Retry-After: a\tb\r\n"]) {
            @Expect(ProductHttpExchangeHeadParser().push(("HTTP/1.1 429 Limited\r\n" + value + "Content-Length: 0\r\n\r\n").toArray()).isError())
        }
    }
}
