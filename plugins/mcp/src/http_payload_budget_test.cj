package mcp_client_plugin

import std.unittest.*
import std.unittest.testmacro.*

func httpPayloadBudgetCode(action: () -> Unit): String {
    try { action(); "unexpected-success" } catch (error: PluginFailure) { error.code }
}

@Test
class HttpPayloadBudgetTests {
    @TestCase
    func metadataCannotHideJsonNodesAcrossSingleByteChunks(): Unit {
        let json = "{\"result\":[{\"value\":null},{\"text\":\"a\\\"b\\\\c\"}]}"
        let wire = "id: \"\nevent: \"\n: \"\ndata: " + json + "\n\n"
        let counter = HttpPayloadTokenCounter(true)
        var nodes: Int64 = 0
        for (byte in wire.toArray()) { nodes += counter.accept([byte]) }
        @Expect(nodes, payloadNodeCount(json))
        // Empty chunks and a second event do not reset the window's cost.
        @Expect(counter.accept(Array<Byte>()), 0)
        nodes += counter.accept(("data: " + json + "\r\n\r\n").toArray())
        @Expect(nodes, payloadNodeCount(json) * 2)
    }

    @TestCase
    func denseSseCannotBypassBoundUsingMetadataOrChunkSplits(): Unit {
        let counter = HttpPayloadTokenCounter(true)
        let _ = counter.accept("id: \"\nevent: \"\ndata: [".toArray())
        let chunk = Array<Byte>(16384, repeat: b',')
        @Expect(httpPayloadBudgetCode({ =>
            for (_ in 0..4) { let _ = counter.accept(chunk) }
        }), "mcp_plugin.payload_nodes")
    }

    @TestCase
    func jsonQuotedPunctuationDoesNotInventDomNodes(): Unit {
        let json = "{\"text\":\"[{,:\\\"}]\",\"nested\":[null,true,7]}"
        let counter = HttpPayloadTokenCounter(false)
        var nodes: Int64 = 0
        for (byte in json.toArray()) { nodes += counter.accept([byte]) }
        @Expect(nodes, payloadNodeCount(json))
    }

    @TestCase
    func realOwnerGrowsOnlyAdditionalDomCostAndRetainsItUntilClose(): Unit {
        let pool = PayloadPool()
        let owner = pool.acquire(8388608) // The actual worker's 64 MiB result lease.
        var competing: ?PayloadCharge = Some(pool.acquire(33554432, transfer: false))
        try {
            @Expect(httpPayloadBudgetCode({ => owner.ensureDecoded(8388608, 65536) }), "mcp_plugin.payload_capacity")
            competing.getOrThrow().close(); competing = None
            owner.ensureDecoded(8388608, 65536) // 65 MiB including DOM; only grows by 1 MiB.
            owner.ensureDecoded(8388608, 65536) // Repeated accounting does not double charge.
            @Expect(httpPayloadBudgetCode({ =>
                let other = pool.acquire(33554432, transfer: false); other.close()
            }), "mcp_plugin.payload_capacity")
            owner.close(); owner.close()
            competing = Some(pool.acquire(33554432, transfer: false))
            let another = pool.acquire(33554432, transfer: false)
            another.close()
            @Expect(httpPayloadBudgetCode({ => owner.ensureDecoded(1, 1) }), "mcp_plugin.http_decode_owner_closed")
        } finally {
            owner.close()
            match (competing) { case Some(value) => value.close(); case None => () }
        }
    }

    @TestCase
    func nodeAndByteCeilingsApplyBeforeBudgetGrowth(): Unit {
        let pool = PayloadPool(); let owner = pool.acquire(1)
        try {
            @Expect(httpPayloadBudgetCode({ => owner.ensureDecoded(1, 65537) }), "mcp_plugin.http_decode_limit")
            @Expect(httpPayloadBudgetCode({ => owner.ensureDecoded(8388609, 1) }), "mcp_plugin.http_decode_limit")
            owner.ensureDecoded(1, 1)
        } finally { owner.close() }
    }

    @TestCase
    func logicalInputKeepsSixteenMibCeilingAndChargesDenseNodesBeforeParse(): Unit {
        let pool = PayloadPool(); let owner = pool.acquire(1)
        var competing: ?PayloadCharge = Some(pool.acquire(33554432, transfer: false))
        try {
            // Sparse logical input above the HTTP response ceiling stays supported.
            @Expect(httpPayloadBudgetCode({ => owner.ensureLogicalDecoded(9437184, 4) }), "mcp_plugin.payload_capacity")
            competing.getOrThrow().close(); competing = None
            owner.ensureLogicalDecoded(9437184, 4)
            @Expect(httpPayloadBudgetCode({ => owner.ensureLogicalDecoded(16777217, 1) }), "mcp_plugin.payload_decode_limit")
        } finally {
            owner.close()
            match (competing) { case Some(value) => value.close(); case None => () }
        }
        let dense = pool.acquire(1)
        try {
            dense.ensureLogicalDecoded(131072, 65536)
            let blocker = pool.acquire(33554432, transfer: false)
            try {
                @Expect(httpPayloadBudgetCode({ =>
                    let other = pool.acquire(16777216, transfer: false); other.close()
                }), "mcp_plugin.payload_capacity")
            } finally { blocker.close() }
        } finally { dense.close() }
    }
}
