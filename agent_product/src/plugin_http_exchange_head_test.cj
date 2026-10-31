package agent_product

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginHttpExchangeHeadTests {
    @TestCase
    func splitMetadataAndInterimResponsesPreserveExactBinaryPrefix(): Unit {
        let source = ("HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200\r\n" +
            "Content-Type: application/octet-stream\r\nContent-Length: 3\r\n" +
            "Set-Cookie: private-metadata\r\n\r\n").toArray()
        // Every split, including every CR/LF boundary and the final delimiter.
        for (split in 0..source.size) {
            let parser = ProductHttpExchangeHeadParser()
            @Expect(lifecycleTestRequire(parser.push(source[..split])).isNone())
            let tail = ArrayList<Byte>()
            tail.add(all: source[split..]); tail.add(all: [0u8, 255u8, 10u8])
            let head = lifecycleTestRequire(parser.push(tail.toArray())).getOrThrow()
            @Expect(head.status, 200)
            @Expect(head.contentType, "application/octet-stream")
            @Expect(head.bodySize.getOrThrow(), 3)
            @Expect(lifecycleTestRequire(parser.takeBodyPrefix()), [0u8, 255u8, 10u8])
            @Expect(parser.takeBodyPrefix().isError())
            @Expect(lifecycleTestRequire(parser.endOfStream()).status, 200)
        }
        let unknown = ProductHttpExchangeHeadParser()
        let head = lifecycleTestRequire(unknown.push("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".toArray())).getOrThrow()
        @Expect(head.bodySize.isNone())
        @Expect(lifecycleTestRequire(unknown.takeBodyPrefix()).isEmpty())
        let notModified = ProductHttpExchangeHeadParser(maxBodyBytes: 2)
        let unchanged = lifecycleTestRequire(notModified.push(
            "HTTP/1.1 304 Not Modified\r\nContent-Length: 999999\r\n\r\n".toArray())).getOrThrow()
        @Expect(unchanged.bodySize.getOrThrow(), 0)
        let opaque = ArrayList<Byte>()
        opaque.add(all: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Private: ".toArray())
        opaque.add(all: [255u8, 195u8]); opaque.add(all: "\r\n\r\n".toArray())
        @Expect(lifecycleTestRequire(ProductHttpExchangeHeadParser().push(opaque.toArray()))
            .getOrThrow().contentType, "application/json")
    }

    @TestCase
    func malformedAndAmbiguousMetadataNeverProducesAHead(): Unit {
        for (header in [
            "HTTP/1.1 200 OK\nInjected: yes\r\n\r\n",
            "HTTP/1.1 200 OK\r\n folded: yes\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: a\r\nContent-Type: b\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
            "HTTP/1.1 101 Switching Protocols\r\n\r\n",
            "HTTP/1.1 204 Empty\r\nContent-Length: 1\r\n\r\n",
            "HTTP/1.1 204 Empty\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 100 Wait\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 600 Invalid\r\n\r\n",
            "HTTP/9 200 Invalid\r\n\r\n"
        ]) {
            let parser = ProductHttpExchangeHeadParser()
            @Expect(parser.push(header.toArray()).isError())
            @Expect(parser.endOfStream().isError())
            @Expect(parser.takeBodyPrefix().isError())
            @Expect(parser.push("HTTP/1.1 200 OK\r\n\r\n".toArray()).isError())
        }
    }

    @TestCase
    func headerBudgetIsCumulativeAndBodyBoundsRemainIndependent(): Unit {
        let partial = ProductHttpExchangeHeadParser(maxHeaderBytes: 32)
        @Expect(lifecycleTestRequire(partial.push("HTTP/1.1 200 OK\r\n".toArray())).isNone())
        @Expect(partial.endOfStream().isError())
        let cumulative = ProductHttpExchangeHeadParser(maxHeaderBytes: 32)
        @Expect(lifecycleTestRequire(cumulative.push("HTTP/1.1 100 Wait\r\n\r\n".toArray())).isNone())
        @Expect(cumulative.push("HTTP/1.1 200 OK\r\n\r\n".toArray()).isError())
        let over = ProductHttpExchangeHeadParser(maxBodyBytes: 2)
        @Expect(over.push("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".toArray()).isError())
        let prefix = ProductHttpExchangeHeadParser(maxBodyBytes: 2)
        @Expect(prefix.push("HTTP/1.1 200 OK\r\n\r\nabc".toArray()).isError())
        let shorter = ProductHttpExchangeHeadParser()
        @Expect(shorter.push("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nab".toArray()).isError())
        let full = ProductHttpExchangeHeadParser()
        @Expect(full.push(Array<Byte>(8193, repeat: 32u8)).isError())
    }
}
